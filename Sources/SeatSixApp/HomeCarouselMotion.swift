import Foundation

/// Presentation state is separate from the user's requested selection. While a
/// slide is moving, further input is coalesced to the latest destination rather
/// than interrupting the current pair of surfaces halfway through the viewport.
struct HomeCarouselMotion {
    private(set) var currentID: String?
    // Unlike the animation generation, this survives a reset to the same slide.
    // A fresh carousel's initial presentation has no explicit selection.
    private(set) var selectionID: UUID?
    private(set) var outgoingID: String?
    private(set) var direction = 1
    private(set) var progress: Double = 1
    private(set) var generation = 0
    private(set) var pendingID: String?
    private var pendingDirection = 1

    var isTransitioning: Bool { outgoingID != nil }

    /// Used when the source, recommendation set, visibility or motion policy
    /// changes. Completion callbacks belonging to the old presentation expire.
    mutating func reset(to id: String?) {
        generation &+= 1
        display(id)
        outgoingID = nil
        pendingID = nil
        pendingDirection = 1
        direction = 1
        progress = 1
    }

    /// Returns true only when a new animated pair needs to be driven by the UI.
    @discardableResult
    mutating func request(id: String, direction requestedDirection: Int, animated: Bool) -> Bool {
        guard !id.isEmpty else { return false }
        guard animated, currentID != nil else {
            reset(to: id)
            return false
        }
        if isTransitioning {
            // Returning to the already arriving slide cancels a queued jump.
            pendingID = id == currentID ? nil : id
            pendingDirection = normalized(requestedDirection)
            return false
        }
        guard id != currentID else { return false }
        begin(id: id, direction: requestedDirection)
        return true
    }

    mutating func setProgress(_ value: Double, generation expectedGeneration: Int) {
        guard generation == expectedGeneration, isTransitioning, value.isFinite else { return }
        progress = min(1, max(0, value))
    }

    /// Called by the animation completion, not a wall-clock delay. Returns true
    /// when a queued destination starts another animation with a new generation.
    @discardableResult
    mutating func finish(generation expectedGeneration: Int) -> Bool {
        guard generation == expectedGeneration, isTransitioning else { return false }
        let nextID = pendingID
        let nextDirection = pendingDirection
        outgoingID = nil
        pendingID = nil
        progress = 1
        guard let nextID, nextID != currentID else { return false }
        begin(id: nextID, direction: nextDirection)
        return true
    }

    /// Neighbors remain mounted to prepare their images. At most five unique
    /// works are retained: the visible pair, two neighbors and the latest intent.
    func renderedIDs(in ids: [String]) -> [String] {
        let available = Set(ids)
        var candidates = [currentID, outgoingID]
        if let currentID, let index = ids.firstIndex(of: currentID), !ids.isEmpty {
            candidates.append(ids[(index + ids.count - 1) % ids.count])
            candidates.append(ids[(index + 1) % ids.count])
        }
        candidates.append(pendingID)
        var seen = Set<String>()
        return candidates.compactMap { id in
            guard let id, available.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Offsets are measured in viewport widths. The outgoing slide and arriving
    /// slide always move together, including first/last-item wraparound.
    func offset(for id: String) -> Double {
        guard isTransitioning else { return 0 }
        if id == currentID { return Double(direction) * (1 - progress) }
        if id == outgoingID { return -Double(direction) * progress }
        return 0
    }

    func isVisible(_ id: String) -> Bool { id == currentID || id == outgoingID }
    func isInteractive(_ id: String) -> Bool { id == currentID }

    private mutating func display(_ id: String?) {
        if currentID != nil, id != currentID { selectionID = UUID() }
        currentID = id
    }

    private mutating func begin(id: String, direction requestedDirection: Int) {
        generation &+= 1
        outgoingID = currentID
        display(id)
        direction = normalized(requestedDirection)
        progress = 0
    }

    private func normalized(_ value: Int) -> Int { value < 0 ? -1 : 1 }
}
