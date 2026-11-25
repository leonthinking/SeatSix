#!/usr/bin/env python3
"""Exercise actual server APIs using synthetic fixtures; does not test AVPlayer."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import time
import urllib.parse

from common import API, CREDENTIALS, DEVICE_ID, RUNTIME, SERVERS, fixture_named, inspect_owned


PROFILE = {
    "Name": "SeatSix AVPlayer",
    "MaxStreamingBitrate": 8_000_000,
    "MaxStaticBitrate": 200_000_000,
    "MusicStreamingTranscodingBitrate": 192_000,
    "DirectPlayProfiles": [{"Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac"}],
    "TranscodingProfiles": [{"Container": "ts", "Type": "Video", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2", "MinSegments": 2, "BreakOnNonKeyFrames": False, "Context": "Streaming"}],
    "CodecProfiles": [{"Type": "Video", "Codec": "h264", "Conditions": [{"Condition": "LessThanEqual", "Property": "Width", "Value": "1920", "IsRequired": True}, {"Condition": "LessThanEqual", "Property": "Height", "Value": "1080", "IsRequired": True}]}],
    "SubtitleProfiles": [],
}


def assert_check(condition, label):
    if not condition:
        raise RuntimeError(f"Integration assertion failed: {label}")


def manifest_segment(api, raw_url):
    origin = api.base.removesuffix(SERVERS[api.kind]["prefix"]) if SERVERS[api.kind]["prefix"] else api.base
    url = urllib.parse.urljoin(origin + "/", raw_url)
    for _ in range(3):
        content = api.fetch("GET", url, raw=True).decode()
        assert_check(content.startswith("#EXTM3U"), "HLS playlist signature")
        lines = [line.strip() for line in content.splitlines() if line.strip() and not line.startswith("#")]
        assert_check(lines, "nonempty HLS playlist")
        url = urllib.parse.urljoin(url, lines[0])
        if ".m3u8" not in urllib.parse.urlsplit(url).path:
            data = api.fetch("GET", url, raw=True, limit=4096)
            assert_check(len(data) >= 188 and data[0] == 0x47, "MPEG TS media segment bytes")
            return len(data)
    raise RuntimeError("HLS nested playlists exceeded 3 levels")


def run_server(kind, credential):
    assert_check(inspect_owned(kind), f"owned {kind} container exists")
    api = API(kind)
    public = api.request("GET", "/System/Info/Public")
    user = api.login(credential)
    uid = user["Id"]
    views = api.request("GET", f"/Users/{uid}/Views")["Items"]
    library = fixture_named(views, "Test Movies")
    assert_check(library, "synthetic movie library")
    listing = api.request("GET", f"/Users/{uid}/Items", query={"ParentId": library["Id"], "Recursive": "true", "IncludeItemTypes": "Movie", "Fields": "Overview,MediaSources", "EnableUserData": "true", "Limit": 60, "StartIndex": 0})
    items = listing["Items"]
    assert_check(len(items) >= 2, "at least two artificial movies")
    evidence = {"kind": kind, "server_version": public.get("Version"), "library_count": len(views), "movie_count": len(items), "login": "passed", "browse": "passed", "playback": []}
    for title, compatible in [("Direct Test", False), ("Compatibility Test", True)]:
        item = fixture_named(items, title)
        assert_check(item, f"synthetic {title} movie")
        detail = api.request("GET", f"/Users/{uid}/Items/{item['Id']}")
        assert_check(detail["Id"] == item["Id"] and detail.get("RunTimeTicks", 0) > 0, "detail identity and duration")
        info = api.request("POST", f"/Items/{item['Id']}/PlaybackInfo", {"DeviceProfile": PROFILE}, query={"UserId": uid, "StartTimeTicks": 0, "IsPlayback": "true", "AutoOpenLiveStream": "false", "MaxStreamingBitrate": 8_000_000, "EnableDirectPlay": "false" if compatible else "true", "EnableDirectStream": "false", "EnableTranscoding": "true"})
        source = info["MediaSources"][0]
        assert_check(info.get("PlaySessionId"), "play session ID")
        common = {"ItemId": item["Id"], "MediaSourceId": source["Id"], "PlaySessionId": info["PlaySessionId"], "PlayMethod": "Transcode" if compatible else "DirectPlay"}
        started = False
        try:
            if compatible:
                assert_check(source.get("SupportsTranscoding") and source.get("TranscodingUrl"), "transcoding URL offered")
                media_bytes = manifest_segment(api, source["TranscodingUrl"])
            else:
                assert_check(source.get("SupportsDirectPlay"), "direct play offered")
                data = api.request("GET", f"/Videos/{item['Id']}/stream.mp4", query={"Static": "true", "MediaSourceId": source["Id"], "PlaySessionId": info["PlaySessionId"], "DeviceId": DEVICE_ID}, raw=True, limit=4096)
                assert_check(len(data) >= 12 and data[4:8] == b"ftyp", "MP4 data signature")
                media_bytes = len(data)
            api.request("POST", "/Sessions/Playing", {**common, "PositionTicks": 0, "CanSeek": True, "IsPaused": False})
            started = True
            position = 1_200_000_000  # 120 seconds, well inside typical server resume thresholds.
            api.request("POST", "/Sessions/Playing/Progress", {**common, "PositionTicks": position, "CanSeek": True, "IsPaused": True, "EventName": "timeupdate"})
            api.request("POST", "/Sessions/Playing/Stopped", {**common, "PositionTicks": position})
            started = False
            deadline = time.monotonic() + 15
            while True:
                saved = api.request("GET", f"/Users/{uid}/Items/{item['Id']}").get("UserData", {}).get("PlaybackPositionTicks")
                if saved == position:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{kind}: server resume position did not reach 120 seconds")
                time.sleep(0.5)
            resume = api.request("GET", f"/Users/{uid}/Items/Resume", query={"ParentId": library["Id"], "Limit": 20, "MediaTypes": "Video"})
            assert_check(any(x["Id"] == item["Id"] for x in resume["Items"]), "item appears in remote resume list")
            evidence["playback"].append({"fixture": item["Name"], "mode": common["PlayMethod"], "media_bytes_read": media_bytes, "start_progress_stop": "passed", "remote_resume_ticks": saved, "remote_resume_list": "passed"})
        finally:
            if started:
                api.request("POST", "/Sessions/Playing/Stopped", {**common, "PositionTicks": 0})
            if compatible:
                api.request("DELETE", "/Videos/ActiveEncodings", query={"DeviceId": DEVICE_ID, "PlaySessionId": info["PlaySessionId"]})
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", choices=list(SERVERS), help="Default: both owned servers")
    args = parser.parse_args()
    credentials = json.loads(CREDENTIALS.read_text())
    results = [run_server(kind, credentials[kind]) for kind in ([args.server] if args.server else SERVERS)]
    evidence = {"verified_at": datetime.now(timezone.utc).isoformat(), "scope": "Real local server API + actual MP4/HLS bytes; no AVPlayer verification", "results": results}
    (RUNTIME / "integration-results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, StopIteration, FileNotFoundError) as exc:
        raise SystemExit(str(exc) or "Expected synthetic fixture not found; run setup.py first") from None
