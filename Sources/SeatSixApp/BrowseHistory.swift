import SeatSixCore

struct SeriesPresentation: Equatable {
    var showsAll = false
    var returnsToPreview = false
    var batch = 0
    var selectedEpisodeID: String?
}

struct DetailLocation {
    let item: MediaItem
    let seasonID: String
    let sequence: EpisodeSequence?
    var seriesPresentation = SeriesPresentation()
}

/// A visit belongs to the connection and authorized libraries that produced it.
/// Keep the detail path so forward navigation restores the original nested return.
struct BrowseVisit {
    let connection: ServerConnection?
    let page: String
    let libraryID: String
    let libraryQuery: LibraryQuery
    let searchTerm: String
    let searchDraft: String
    let detail: DetailLocation?
    let parents: [DetailLocation]
    let detailOriginPage: String

    func matches(page: String, libraryID: String, itemID: String?) -> Bool {
        self.page == page && self.libraryID == libraryID && detail?.item.id == itemID
    }
}

struct BrowseHistory {
    private(set) var back: [BrowseVisit] = []
    private(set) var forward: [BrowseVisit] = []

    mutating func depart(_ current: BrowseVisit) {
        back.append(current)
        if back.count > 64 { back.removeFirst() }
        forward.removeAll()
    }

    mutating func stepBack(from current: BrowseVisit) -> BrowseVisit? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    mutating func stepForward(from current: BrowseVisit) -> BrowseVisit? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }

    /// “查看全部分集” can return through multiple details at once. They become
    /// forward visits in the same order as repeated Back actions.
    mutating func returnFromDetail(_ current: BrowseVisit, to itemID: String?, on page: String) {
        forward.append(current)
        guard let ancestor = back.lastIndex(where: {
            $0.connection == current.connection && $0.matches(page: page, libraryID: current.libraryID, itemID: itemID)
        }) else { return }
        forward.append(contentsOf: back.suffix(from: ancestor + 1).reversed())
        back.removeSubrange(ancestor...)
    }
}
