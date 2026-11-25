"""Read-only capability audit. Never persists server bodies, IDs, titles or credentials.

Run from the project root: python3 -B -m scripts.emby_audit.audit --config PRIVATE_JSON
The output is a bounded, anonymous observation record, not a universal capability flag.
"""
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from .transport import AuditClient, AuditError


FIELDS = "Overview,Genres,GenreItems,People,Studios,Chapters,MediaSources,MediaStreams,ProviderIds,DateCreated,SortName,Tags"
NO_MATCH = "seatsix_capability_audit_no_match_7fbc2d918a"
DETAIL_FIELDS = ("Overview", "Genres", "GenreItems", "People", "Studios", "Chapters", "MediaSources", "MediaStreams", "ProviderIds", "Tags", "ImageTags", "BackdropImageTags", "ProductionYear", "CommunityRating", "OfficialRating", "RunTimeTicks")


def items(data):
    if isinstance(data, list):
        return [v for v in data if isinstance(v, dict)]
    if isinstance(data, dict) and isinstance(data.get("Items"), list):
        return [v for v in data["Items"] if isinstance(v, dict)]
    return []


def ids(values):
    return [str(v["Id"]) for v in values if isinstance(v, dict) and v.get("Id") is not None]


def object_value(value):
    return value if isinstance(value, dict) else {}


def object_rows(value):
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def require_object(value, row):
    if not isinstance(value, dict):
        if row["status"] == 200:
            row["observation"] = "wrong-shape"
        return {}
    return value


def user_state(item):
    data = object_value(object_value(item).get("UserData"))
    if (type(data.get("Played")) is not bool or type(data.get("IsFavorite")) is not bool
            or type(data.get("PlaybackPositionTicks")) is not int or data["PlaybackPositionTicks"] < 0):
        return None
    return {key: data.get(key) for key in ("Played", "IsFavorite", "PlaybackPositionTicks")}


def valid_catalog_page(data, offset, expected_total=None):
    """Fail closed on any page contract violation; never repair later pages."""
    if not isinstance(data, dict) or not isinstance(data.get("Items"), list):
        return False
    batch = data["Items"]
    total = data.get("TotalRecordCount")
    if (len(batch) > 200 or type(total) is not int or total < offset + len(batch)
            or (expected_total is not None and total != expected_total)
            or ("StartIndex" in data and (type(data["StartIndex"]) is not int or data["StartIndex"] != offset))):
        return False
    if any(not isinstance(v, dict) or not isinstance(v.get("Id"), str) or not v["Id"] for v in batch):
        return False
    return len(set(ids(batch))) == len(batch)


def person_match(item, person_id):
    people = item.get("People")
    if not isinstance(people, list) or any(not isinstance(v, dict) or not v.get("Id") for v in people):
        return None
    return str(person_id) in ids(people)


def genre_match(item, genre):
    names, genres = item.get("Genres"), item.get("GenreItems")
    names_valid = isinstance(names, list) and all(isinstance(v, str) for v in names)
    ids_valid = isinstance(genres, list) and all(isinstance(v, dict) and v.get("Id") for v in genres)
    if not names_valid and not ids_valid:
        return None
    return bool((names_valid and genre.get("Name") in names) or (ids_valid and str(genre["Id"]) in ids(genres)))


def relationship_observation(matches):
    if not matches:
        return "empty-unproven"
    if False in matches:
        return "contradicted"
    return "missing-data" if None in matches else "sample-consistent"


def observed_filter(values, key, expected):
    """Empty results and missing fields cannot prove a filter works."""
    if not values:
        return "empty-unproven"
    flags = [object_value(v.get("UserData")).get(key) for v in values]
    if any(type(flag) is not bool for flag in flags):
        return "missing-data"
    return "sample-consistent" if all(flag == expected for flag in flags) else "contradicted"


def paired_sort(ascending, descending):
    a, b = ids(ascending), ids(descending)
    if len(a) < 2 or len(b) < 2:
        return "insufficient-sample"
    if a == b:
        return "same-order"
    if set(a) == set(b) and a == list(reversed(b)):
        return "reversed-sample"
    return "different-order-unproven"


class Audit:
    def __init__(self, client):
        self.client = client
        self.rows = []

    def read(self, name, path, template, query=None, method="GET", body=None, headers=None):
        row = {"name": name, "method": method, "path": template,
               "status": 0, "shape": "unavailable", "count": 0, "total": 0,
               "observation": "unclassified", "metrics": {}}
        self.rows.append(row)
        try:
            response = self.client.request(path, query=query, method=method, body=body, headers=headers)
        except AuditError:
            row["observation"] = "transport-error"
            return None, row, None
        data = response.data
        row["status"] = response.status
        row["shape"] = "list" if isinstance(data, list) else "items" if isinstance(data, dict) and isinstance(data.get("Items"), list) else "object" if isinstance(data, dict) else "binary-or-empty"
        row["count"] = len(items(data))
        total = data.get("TotalRecordCount") if isinstance(data, dict) else None
        row["total"] = total if type(total) is int and total >= 0 else row["count"]
        row["observation"] = ("http-error" if response.status >= 400 else "redirect-refused" if 300 <= response.status < 400 and response.status != 304 else "empty" if row["shape"] in ("list", "items") and not row["count"] else "data-returned")
        return data, row, response

    def run(self):
        self.client.login()
        uid = quote(self.client.user_id, safe="")
        user_items = f"Users/{uid}/Items"
        item_template = "/Users/{user}/Items"
        info, info_row, _ = self.read("system.info", "System/Info", "/System/Info")
        info = require_object(info, info_row)
        reported_version = str(info.get("Version", ""))
        version = reported_version if re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", reported_version) else "not-recorded"
        user, user_row, _ = self.read("user.policy", f"Users/{uid}", "/Users/{user}")
        user = require_object(user, user_row)
        policy = object_value(user.get("Policy"))
        for key in ("EnableContentDownloading", "EnableRemoteControlOfOtherUsers", "EnableLiveTvAccess", "EnableLiveTvManagement", "EnableMediaPlayback", "IsAdministrator"):
            if type(policy.get(key)) is bool:
                user_row["metrics"][key] = policy[key]
        self.read("library.counts", "Items/Counts", "/Items/Counts", {"UserId": self.client.user_id})
        views, _, _ = self.read("library.views", f"Users/{uid}/Views", "/Users/{user}/Views")
        libraries = items(views)
        catalog = []
        library_records = []
        for index, library in enumerate(libraries[:8], 1):
            lid = library.get("Id")
            if not lid:
                continue
            base = {"ParentId": lid, "IncludeItemTypes": "Movie,Series", "Limit": 200, "StartIndex": 0, "Fields": FIELDS}
            first, first_row, _ = self.read(f"library.{index}.items", user_items, item_template, base)
            page_valid = first_row["status"] == 200 and valid_catalog_page(first, 0)
            loaded = items(first) if page_valid else []
            if not page_valid and first_row["status"] == 200:
                first_row["observation"] = "invalid-pagination"
            total = first_row["total"]
            raw_count = len(loaded)
            seen = set(ids(loaded))
            valid_total = page_valid
            complete = valid_total and first_row["shape"] == "items" and first_row["status"] == 200 and len(seen) == total
            for page in range(1, 5):
                if complete or not loaded:
                    break
                more, more_row, _ = self.read(f"library.{index}.page.{page + 1}", user_items, item_template, {**base, "StartIndex": raw_count})
                batch = items(more)
                if (more_row["status"] != 200 or not valid_catalog_page(more, raw_count, total)
                        or not batch or set(ids(batch)) & seen):
                    if more_row["status"] == 200:
                        more_row["observation"] = "invalid-pagination"
                    break
                raw_count += len(batch)
                loaded.extend(batch)
                seen.update(ids(batch))
                complete = valid_total and more_row["total"] == total and len(seen) == total
            first_row["metrics"].update(loadedUnique=len(set(ids(loaded))), catalogComplete=complete)
            catalog.extend(loaded)
            library_records.append({"case": index, "loaded": len(loaded), "total": total, "complete": complete})
            self.read(f"library.{index}.folders", user_items, item_template, {"ParentId": lid, "IncludeItemTypes": "Folder", "Limit": 20})
            mixed, _, _ = self.read(f"library.{index}.mixed", user_items, item_template, {"ParentId": lid, "Limit": 20})
            for folder in [v for v in items(mixed) if v.get("Type") == "Folder"][:1]:
                self.read(f"library.{index}.collection-members", user_items, item_template, {"ParentId": folder["Id"], "Limit": 20})
            latest, _, _ = self.read(f"library.{index}.latest", user_items + "/Latest", item_template + "/Latest", {"ParentId": lid, "MediaTypes": "Video", "Limit": 10})
            latest_unplayed, row, _ = self.read(f"library.{index}.latest-unplayed", user_items + "/Latest", item_template + "/Latest", {"ParentId": lid, "MediaTypes": "Video", "IsPlayed": "false", "Limit": 10})
            row["observation"] = observed_filter(items(latest_unplayed), "Played", False) if row["status"] == 200 else row["observation"]
            genres, _, _ = self.read(f"library.{index}.genres", "Genres", "/Genres", {"ParentId": lid, "UserId": self.client.user_id, "Limit": 50})
            genre = next((v for v in items(genres) if v.get("Id")), None)
            if genre:
                filtered, row, _ = self.read(f"library.{index}.genre-filter", user_items, item_template, {**base, "GenreIds": genre["Id"]})
                matches = [genre_match(v, genre) for v in items(filtered)]
                row["metrics"].update(matchedGenreItems=sum(v is True for v in matches), sampledItems=len(matches))
                if row["status"] == 200:
                    row["observation"] = relationship_observation(matches)
            if not loaded:
                continue
            # Limit semantics to three populated libraries; pagination/browse still covers all eight.
            if index > 3:
                continue
            negative, row, _ = self.read(f"library.{index}.search-negative", user_items, item_template, {**base, "SearchTerm": NO_MATCH})
            if row["status"] == 200:
                row["observation"] = "contradicted" if items(negative) else "empty-consistent"
            name = loaded[0].get("Name")
            if isinstance(name, str) and name:
                positive, row, _ = self.read(f"library.{index}.search-positive", user_items, item_template, {**base, "SearchTerm": name})
                matches = [name.casefold() in str(v.get("Name", "")).casefold() for v in items(positive)]
                row["metrics"].update(matchingNames=sum(matches), sampledItems=len(matches))
                if row["status"] == 200:
                    row["observation"] = "sample-consistent" if matches and all(matches) else "contradicted" if matches else "empty-unproven"
            ascending, _, _ = self.read(f"library.{index}.sort-name-asc", user_items, item_template, {**base, "SortBy": "SortName", "SortOrder": "Ascending"})
            descending, row, _ = self.read(f"library.{index}.sort-name-desc", user_items, item_template, {**base, "SortBy": "SortName", "SortOrder": "Descending"})
            if row["status"] == 200:
                row["observation"] = paired_sort(items(ascending), items(descending))
            for played in (False, True):
                values, row, _ = self.read(f"library.{index}.played-{str(played).lower()}", user_items, item_template, {**base, "IsPlayed": str(played).lower()})
                if row["status"] == 200:
                    row["observation"] = observed_filter(items(values), "Played", played)
        resume, row, _ = self.read("home.resume", user_items + "/Resume", item_template + "/Resume", {"StartIndex": 0, "Limit": 20})
        row["metrics"]["seriesWithoutEpisodeIdentity"] = sum(v.get("Type") == "Series" and not v.get("EpisodeId") for v in items(resume))
        for typ in ("Movie", "Series", "Episode", "Video"):
            row["metrics"][typ + "Count"] = sum(v.get("Type") == typ for v in items(resume))
        row["metrics"]["matchedCatalogItems"] = sum(str(v.get("Id")) in set(ids(catalog)) for v in items(resume))
        row["metrics"]["episodesWithCatalogSeries"] = sum(v.get("Type") == "Episode" and str(v.get("SeriesId")) in set(ids(catalog)) for v in items(resume))
        resume_negative, row, _ = self.read("home.resume-parent-negative", user_items + "/Resume", item_template + "/Resume", {"StartIndex": 0, "Limit": 20, "ParentId": NO_MATCH})
        if row["status"] == 200:
            row["observation"] = "contradicted" if items(resume_negative) else "empty-consistent"
            row["metrics"]["sameItemsAsUnfiltered"] = bool(items(resume)) and ids(items(resume_negative)) == ids(items(resume))
        favorite, row, _ = self.read("home.favorites", user_items, item_template, {"Filters": "IsFavorite", "IncludeItemTypes": "Movie,Series", "StartIndex": 0, "Limit": 50})
        if row["status"] == 200:
            row["observation"] = observed_filter(items(favorite), "IsFavorite", True)
        self.read("home.nextup-global", "Shows/NextUp", "/Shows/NextUp", {"UserId": self.client.user_id, "Limit": 10})
        self.read("home.recommendations", "Movies/Recommendations", "/Movies/Recommendations", {"UserId": self.client.user_id, "ItemLimit": 5, "CategoryLimit": 2})
        self.read("home.suggestions", user_items + "/Suggestions", item_template + "/Suggestions", {"Limit": 10, "Type": "Movie,Series"})
        self.read("search.hints", "Search/Hints", "/Search/Hints", {"UserId": self.client.user_id, "SearchTerm": NO_MATCH, "Limit": 10})
        self.read("session.list", "Sessions", "/Sessions", {"ControllableByUserId": self.client.user_id})
        self.read("livetv.channels", "LiveTv/Channels", "/LiveTv/Channels", {"UserId": self.client.user_id, "Limit": 1})
        self.read("sync.jobs", "Sync/Jobs", "/Sync/Jobs", {"UserId": self.client.user_id, "Limit": 1})
        self.read("library.playlists", user_items, item_template, {"IncludeItemTypes": "Playlist", "Recursive": "true", "Limit": 5})
        persons, _, _ = self.read("people.list", "Persons", "/Persons", {"UserId": self.client.user_id, "Limit": 5})
        for index, person in enumerate(items(persons)[:2], 1):
            if person.get("Id"):
                self.read(f"people.{index}.detail", user_items + "/" + quote(str(person["Id"]), safe=""), item_template + "/{person}")
                works, row, _ = self.read(f"people.{index}.works", user_items, item_template, {"PersonIds": person["Id"], "IncludeItemTypes": "Movie,Series", "Limit": 20, "Fields": "People"})
                matches = [person_match(v, person["Id"]) for v in items(works)]
                row["metrics"].update(matchedPersonItems=sum(v is True for v in matches), sampledItems=len(matches))
                if row["status"] == 200:
                    row["observation"] = relationship_observation(matches)
                # Compatible lists can omit People despite Fields=People. Verify
                # a bounded subset using actual item details, not just HTTP 200.
                verified = 0
                checked = 0
                for work_index, work in enumerate(items(works)[:2], 1):
                    if not work.get("Id"):
                        continue
                    work_detail, work_row, _ = self.read(f"people.{index}.work-detail.{work_index}", user_items + "/" + quote(str(work["Id"]), safe=""), item_template + "/{item}")
                    work_detail = require_object(work_detail, work_row)
                    matched = work_row["status"] == 200 and person_match(work_detail, person["Id"]) is True
                    work_row["metrics"]["containsSelectedPerson"] = matched
                    checked += work_row["status"] == 200
                    verified += matched
                row["metrics"].update(detailCheckedItems=checked, detailMatchedPersonItems=verified)

        unique = {str(v["Id"]): v for v in catalog if v.get("Id")}
        samples = [v for v in unique.values() if v.get("Type") == "Movie"][:4] + [v for v in unique.values() if v.get("Type") == "Series"][:4]
        metadata = {key: 0 for key in DETAIL_FIELDS}
        segments_summary = {"requests": 0, "nonemptyResponses": 0, "validIntervals": 0, "invalidIntervals": 0, "introIntervals": 0, "outroIntervals": 0}
        detail_count = 0
        state_checks = []
        for index, sample in enumerate(samples, 1):
            item_id = quote(str(sample["Id"]), safe="")
            detail, row, _ = self.read(f"sample.{index}.detail", user_items + "/" + item_id, item_template + "/{item}", {"Fields": FIELDS})
            if row["status"] != 200 or not isinstance(detail, dict):
                require_object(detail, row)
                continue
            detail_count += 1
            state_checks.append((item_id, user_state(detail)))
            for field in DETAIL_FIELDS:
                metadata[field] += bool(detail.get(field))
            row["metrics"]["mediaSourceCount"] = len(object_rows(detail.get("MediaSources")))
            row["metrics"]["chapterCount"] = len(object_rows(detail.get("Chapters")))
            row["metrics"]["markerChapterCount"] = sum(c.get("MarkerType") in ("IntroStart", "IntroEnd", "CreditsStart") for c in object_rows(detail.get("Chapters")))
            self.read(f"sample.{index}.similar", f"Items/{item_id}/Similar", "/Items/{item}/Similar", {"UserId": self.client.user_id, "Limit": 5})
            if index == 1:
                self.read("sample.1.additional-parts", f"Videos/{item_id}/AdditionalParts", "/Videos/{item}/AdditionalParts", {"UserId": self.client.user_id})
                self.read("sample.1.special-features", user_items + f"/{item_id}/SpecialFeatures", item_template + "/{item}/SpecialFeatures")
                self.read("sample.1.local-trailers", user_items + f"/{item_id}/LocalTrailers", item_template + "/{item}/LocalTrailers")
                self.read("sample.1.download-head", f"Items/{item_id}/Download", "/Items/{item}/Download", method="HEAD")
                self.read("sample.1.chapter-image-head", f"Items/{item_id}/Images/Chapter/0", "/Items/{item}/Images/Chapter/{index}", method="HEAD")
                for image_type in ("Primary", "Backdrop", "Logo"):
                    _, row, image = self.read("sample.1.image-" + image_type.lower(), f"Items/{item_id}/Images/{image_type}", "/Items/{item}/Images/{type}", method="HEAD")
                    row["metrics"]["imageContentType"] = bool(image and image.headers.get("content-type", "").lower().startswith("image/"))
            targets = [detail]
            if sample.get("Type") == "Series":
                self.read(f"sample.{index}.seasons", f"Shows/{item_id}/Seasons", "/Shows/{series}/Seasons")
                episodes, _, _ = self.read(f"sample.{index}.episodes", f"Shows/{item_id}/Episodes", "/Shows/{series}/Episodes", {"Fields": "MediaStreams,MediaSources"})
                targets = items(episodes)[:8]
                nextup, row, _ = self.read(f"sample.{index}.nextup", "Shows/NextUp", "/Shows/NextUp", {"SeriesId": sample["Id"], "StartIndex": 0, "Limit": 1})
                candidates = items(nextup)
                row["metrics"]["memberOfEpisodeList"] = bool(candidates) and all(str(v.get("Id")) in set(ids(items(episodes))) for v in candidates)
                row["metrics"]["unplayedCandidate"] = bool(candidates) and all(object_value(v.get("UserData")).get("Played") is False for v in candidates)
            for subindex, target in enumerate(targets, 1):
                target_id = quote(str(target.get("Id", "")), safe="")
                if not target_id:
                    continue
                segments, row, _ = self.read(f"sample.{index}.segments.{subindex}", f"MediaSegments/{target_id}", "/MediaSegments/{item}", {"includeSegmentTypes": "Intro,Outro"})
                segments_summary["requests"] += 1
                segments_summary["nonemptyResponses"] += bool(items(segments))
                valid_count = 0
                for segment in items(segments):
                    start, end = segment.get("StartTicks"), segment.get("EndTicks")
                    duration = target.get("RunTimeTicks")
                    valid = type(start) is int and type(end) is int and 0 <= start < end and type(duration) is int and end <= duration
                    segments_summary["validIntervals" if valid else "invalidIntervals"] += 1
                    valid_count += valid
                    for typ, key in (("Intro", "introIntervals"), ("Outro", "outroIntervals")):
                        segments_summary[key] += segment.get("Type") == typ
                row["metrics"]["validIntervals"] = valid_count
            if sample.get("Type") == "Movie":
                playback, row, _ = self.read(f"sample.{index}.playback-info", f"Items/{item_id}/PlaybackInfo", "/Items/{item}/PlaybackInfo", method="POST", body={})
                playback = require_object(playback, row)
                sources = object_rows(playback.get("MediaSources"))
                row["metrics"]["mediaSourceCount"] = len(sources)
                row["metrics"]["transcodingAdvertised"] = any(v.get("SupportsTranscoding") is True for v in sources)
                row["metrics"]["externalSubtitleStreams"] = sum(s.get("Type") == "Subtitle" and s.get("IsExternal") is True for v in sources for s in object_rows(v.get("MediaStreams")))
                row["metrics"]["subtitleDeliveryLocations"] = sum(s.get("Type") == "Subtitle" and bool(s.get("DeliveryUrl")) for v in sources for s in object_rows(v.get("MediaStreams")))
        unchanged = 0
        comparable = 0
        for index, (item_id, before) in enumerate(state_checks, 1):
            detail, row, _ = self.read(f"sample.{index}.state-readback", user_items + "/" + item_id, item_template + "/{item}")
            after = user_state(detail)
            valid_state = row["status"] == 200 and before is not None and after is not None
            same = valid_state and after == before
            if row["status"] == 200 and not valid_state:
                row["observation"] = "missing-data"
            row["metrics"]["stateComparable"] = valid_state
            row["metrics"]["unchanged"] = same
            comparable += valid_state
            unchanged += same
        return {"schemaVersion": 1, "verifiedAt": datetime.now(timezone.utc).isoformat(),
                "scope": "private-emby-compatible-server-readonly-api-audit", "reportedVersion": version,
                "transport": {"https": True, "exactLeafPin": True, "redirectsFollowed": False},
                "limits": {"maxLibraries": 8, "maxItemsPerLibrary": 1000, "maxSampleMovies": 4, "maxSampleSeries": 4, "maxEpisodesPerSeries": 8, "userStateWrites": 0, "playbackStarted": False, "uiImplemented": False, "localContainersStarted": False},
                "libraries": library_records, "catalogUniqueItems": len(unique), "detailSampleCount": detail_count, "metadataPresence": metadata,
                "segments": segments_summary, "stateReadback": {"sampleCount": len(state_checks), "comparableCount": comparable, "unchangedCount": unchanged}, "checks": self.rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    client = None
    try:
        client = AuditClient(json.loads(args.config.read_text()))
        report = Audit(client).run()
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"checks": len(report["checks"]), "detailSamples": report["detailSampleCount"], "stateReadback": report["stateReadback"]}))
    except (AuditError, OSError, ValueError, KeyError, TypeError):
        raise SystemExit("API audit failed; no private response content was logged")
    finally:
        if client:
            client.close()


if __name__ == "__main__":
    main()
