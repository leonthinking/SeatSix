import Foundation
import SeatSixCore

/// Read-only acceptance for the same complete-catalog query path used by the app.
/// Public evidence contains counts and assertions; optional UI samples stay private.
enum LibraryCatalogProbe {
    struct Result {
        let report: [String: Any]
        let privateReport: [String: Any]
    }

    static func verify(client: MediaServerClient, libraries: [MediaLibrary]) async throws -> Result {
        var reports: [[String: Any]] = []
        var privateLibraries: [[String: Any]] = []
        for (index, library) in libraries.enumerated() {
            let reference = try await referenceCatalog(client: client, libraryID: library.id)
            let snapshot = try await client.libraryCatalog(libraryID: library.id)
            var report = evaluate(items: snapshot.items, reference: reference.items)
            report["libraryIndex"] = index + 1
            report["complete"] = snapshot.isComplete
            report["declaredTotal"] = snapshot.total
            report["referencePageCount"] = reference.pages
            report["passed"] = report["passed"] as? Bool == true && snapshot.isComplete && snapshot.total == snapshot.items.count
            reports.append(report)

            let facets = LibraryCatalogFacets(items: snapshot.items)
            var privateLibrary: [String: Any] = ["libraryIndex": index + 1, "libraryID": library.id, "libraryName": library.name,
                "years": facets.years, "genres": facets.genres]
            if let sample = reference.items.dropFirst(60).first {
                privateLibrary["beyondFirstPage"] = ["name": sample.name, "year": sample.productionYear.map { $0 as Any } ?? NSNull(),
                    "genres": sample.genres, "watched": sample.userData.played, "referenceIndex": 60]
            }
            if let sample = snapshot.items.first(where: { $0.productionYear != nil && !$0.genres.isEmpty }) {
                privateLibrary["combinedFilter"] = ["name": sample.name, "year": sample.productionYear!,
                    "genre": sample.genres[0], "watched": sample.userData.played]
            }
            privateLibraries.append(privateLibrary)
        }
        let passed = !reports.isEmpty && reports.allSatisfy { $0["passed"] as? Bool == true }
        return Result(report: ["passed": passed, "libraries": reports,
            "catalogItemCount": reports.reduce(0) { $0 + ($1["itemCount"] as? Int ?? 0) },
            "playbackOrUserStateWritesIssued": 0,
            "referencePageSize": 60,
            "scope": "Complete selected library; one independent traversal per library; no playback or user-data mutations"],
            privateReport: ["libraries": privateLibraries])
    }

    /// A second traversal uses the pre-existing 60-item endpoint rather than the new loader.
    /// Counts, offsets, duplicates and a changing catalog fail closed.
    private static func referenceCatalog(client: MediaServerClient, libraryID: String) async throws -> (items: [MediaItem], pages: Int) {
        var items: [MediaItem] = []
        var ids: Set<String> = []
        var total: Int?
        for pageIndex in 0..<2_000 {
            try Task.checkCancellation()
            let page = try await client.items(libraryID: libraryID, startIndex: items.count)
            // MediaPage maps an omitted StartIndex to zero. Official query results
            // may omit that field, so total + unique IDs validate this traversal.
            guard page.totalRecordCount >= 0,
                  page.totalRecordCount <= 100_000,
                  total == nil || total == page.totalRecordCount,
                  items.count + page.items.count <= page.totalRecordCount else {
                throw ProbeFailure(message: "媒体库独立分页校验失败；目录可能在变化，需重试")
            }
            total = page.totalRecordCount
            for item in page.items {
                guard !item.id.isEmpty, ids.insert(item.id).inserted else {
                    throw ProbeFailure(message: "媒体库独立分页出现重复或空 ID，无法验证完整性")
                }
            }
            items.append(contentsOf: page.items)
            if items.count == total { return (items, pageIndex + 1) }
            guard !page.items.isEmpty else { throw ProbeFailure(message: "媒体库独立分页提前结束，无法验证完整性") }
        }
        throw ProbeFailure(message: "媒体库独立分页超过验收上限，未判定通过")
    }

    /// Independent predicates provide an oracle for actual metadata. Empty positive sets
    /// are reported as unavailable, rather than presented as positive watched evidence.
    static func evaluate(items: [MediaItem], reference: [MediaItem]) -> [String: Any] {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let ids = items.map(\.id)
        let referenceIDs = reference.map(\.id)
        check("uniqueIdentifiers", Set(ids).count == ids.count && !ids.contains(""))
        check("independentPaginationIdentitySet", Set(ids) == Set(referenceIDs) && ids.count == referenceIDs.count)
        check("emptyQueryIncludesEntireCatalog", Set(LibraryQuery().apply(to: items).map(\.id)) == Set(ids))
        let negative = "seatsix-no-matching-title-\(UUID().uuidString)"
        check("nonexistentTitleReturnsNoResults", LibraryQuery(text: negative).apply(to: items).isEmpty)
        let beyond = reference.dropFirst(60)
        check("everyTitleBeyondFirstPageIsSearchable", beyond.allSatisfy { item in
            LibraryQuery(text: item.name).apply(to: items).contains { $0.id == item.id }
        })

        let facets = LibraryCatalogFacets(items: items)
        let years = Set(items.compactMap(\.productionYear))
        check("yearFacetsCoverEntireCatalog", Set(facets.years) == years)
        check("genreFacetsCoverEntireCatalog", Set(facets.genres.map(normalized)) == Set(items.flatMap(\.genres).map(normalized).filter { !$0.isEmpty }))
        check("eachYearFilterMatchesMetadata", years.allSatisfy { year in
            Set(LibraryQuery(year: year).apply(to: items).map(\.id)) == Set(items.filter { $0.productionYear == year }.map(\.id))
        })
        check("eachGenreFilterMatchesMetadata", facets.genres.allSatisfy { genre in
            Set(LibraryQuery(genre: genre).apply(to: items).map(\.id)) == Set(items.filter { item in
                item.genres.contains { normalized($0) == normalized(genre) }
            }.map(\.id))
        })
        let watched = items.filter { $0.userData.played }
        let unwatched = items.filter { !$0.userData.played }
        check("watchedFilterMatchesMetadata", Set(LibraryQuery(watched: .watched).apply(to: items).map(\.id)) == Set(watched.map(\.id)))
        check("unwatchedFilterMatchesMetadata", Set(LibraryQuery(watched: .unwatched).apply(to: items).map(\.id)) == Set(unwatched.map(\.id)))
        let combinedSamples = items.filter { $0.productionYear != nil && !$0.genres.isEmpty }
        check("combinedFiltersMatchMetadata", combinedSamples.allSatisfy { sample in
            let genre = sample.genres[0]
            let expected = items.filter { $0.productionYear == sample.productionYear && $0.userData.played == sample.userData.played && $0.genres.contains { normalized($0) == normalized(genre) } }
            let actual = LibraryQuery(year: sample.productionYear, genre: genre,
                watched: sample.userData.played ? .watched : .unwatched).apply(to: items)
            return Set(actual.map(\.id)) == Set(expected.map(\.id)) && actual.contains { $0.id == sample.id }
        })
        check("titleSearchCombinesWithEveryFilter", combinedSamples.allSatisfy { sample in
            let genre = sample.genres[0]
            let terms = normalized(sample.name).split(whereSeparator: { $0.isWhitespace })
            let expected = items.filter { item in
                item.productionYear == sample.productionYear && item.userData.played == sample.userData.played &&
                    item.genres.contains { normalized($0) == normalized(genre) } && terms.allSatisfy { normalized(item.name).contains($0) }
            }
            let actual = LibraryQuery(text: sample.name, year: sample.productionYear, genre: genre,
                watched: sample.userData.played ? .watched : .unwatched).apply(to: items)
            return Set(actual.map(\.id)) == Set(expected.map(\.id)) && actual.contains { $0.id == sample.id }
        })
        let nameAscending = LibraryQuery(sort: .nameAscending).apply(to: items)
        let nameDescending = LibraryQuery(sort: .nameDescending).apply(to: items)
        check("nameSortReversesPrimaryOrder", nameAscending.count == nameDescending.count && zip(nameAscending, nameDescending.reversed()).allSatisfy { pair in
            pair.0.name.compare(pair.1.name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric], locale: Locale(identifier: "zh_Hans_CN")) == .orderedSame
        })
        func adjacentNameOrder(_ values: [MediaItem], ascending: Bool) -> Bool {
            zip(values, values.dropFirst()).allSatisfy { left, right in
                let comparison = left.name.compare(right.name,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
                    locale: Locale(identifier: "zh_Hans_CN"))
                if comparison == .orderedSame { return left.id < right.id }
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }
        }
        check("nameAscendingAdjacentOrder", adjacentNameOrder(nameAscending, ascending: true))
        check("nameDescendingAdjacentOrder", adjacentNameOrder(nameDescending, ascending: false))
        check("nameSortKeepsEveryItem", Set(nameAscending.map(\.id)) == Set(ids) && Set(nameDescending.map(\.id)) == Set(ids))
        check("nameSortIsDeterministic", nameAscending.map(\.id) == LibraryQuery(sort: .nameAscending).apply(to: Array(items.reversed())).map(\.id))
        for (order, name, increasing) in [(LibrarySortOrder.yearAscending, "yearAscendingOrder", true), (.yearDescending, "yearDescendingOrder", false)] {
            let sorted = LibraryQuery(sort: order).apply(to: items)
            let known = sorted.compactMap(\.productionYear)
            check(name, known == (increasing ? known.sorted() : known.sorted(by: >)) && sorted.dropFirst(known.count).allSatisfy { $0.productionYear == nil } && Set(sorted.map(\.id)) == Set(ids))
        }
        return ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks,
            "itemCount": items.count, "watchedCount": watched.count, "unwatchedCount": unwatched.count,
            "watchedPositiveAvailable": !watched.isEmpty, "unwatchedPositiveAvailable": !unwatched.isEmpty,
            "beyondFirstPageTitleCount": beyond.count, "beyondFirstPagePositiveAvailable": !beyond.isEmpty,
            "combinedFilterSampleCount": combinedSamples.count, "yearFacetCount": facets.years.count,
            "genreFacetCount": facets.genres.count]
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
