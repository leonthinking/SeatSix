import Foundation

public enum MediaArtworkRole: String, Hashable, Sendable {
    case poster, landscape, detailBackdrop, logo

    public var isLandscape: Bool { self == .landscape || self == .detailBackdrop }

    public var maximumWidth: Int {
        switch self {
        case .detailBackdrop: 2560
        case .logo: 600
        case .poster, .landscape: 1600
        }
    }

    public func boundedWidth(_ width: Int) -> Int { min(maximumWidth, max(50, width)) }
}

/// A declared server image, never an arbitrary remote URL.
public struct MediaArtworkSource: Equatable, Hashable, Sendable {
    public enum ImageType: String, Hashable, Sendable { case primary = "Primary", backdrop = "Backdrop", thumb = "Thumb", logo = "Logo" }
    public let itemID: String
    public let type: ImageType
    public let tag: String
    public let index: Int?

    public init(itemID: String, type: ImageType, tag: String, index: Int? = nil) {
        self.itemID = itemID; self.type = type; self.tag = tag; self.index = index
    }

    public var isValid: Bool {
        !itemID.isEmpty && itemID.utf8.count <= 256 && itemID.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tag.utf8.count <= 4096
            && (type == .backdrop ? index.map { $0 >= 0 } == true : index == nil)
    }

    public var cacheComponents: [String] { [itemID, type.rawValue, tag, index.map(String.init) ?? ""] }
}

extension MediaItem {
    public func artworkSources(for role: MediaArtworkRole) -> [MediaArtworkSource] {
        if role.isLandscape { return landscapeArtworkSources }
        let type: MediaArtworkSource.ImageType = role == .logo ? .logo : .primary
        guard let tag = imageTags[type.rawValue] else { return [] }
        let source = MediaArtworkSource(itemID: id, type: type, tag: tag)
        return source.isValid ? [source] : []
    }

    /// Do not use an unknown or portrait Primary in a wide slot. Own stills precede
    /// inherited series art; every inherited image requires an explicit owner ID.
    /// Retain up to three declared backdrops per owner so a broken first image can
    /// fall back without allowing an unbounded number of network requests.
    public var landscapeArtworkSources: [MediaArtworkSource] {
        var sources: [MediaArtworkSource] = []
        func append(_ itemID: String?, _ type: MediaArtworkSource.ImageType, _ tag: String?, index: Int? = nil) {
            guard let itemID, let tag else { return }
            let source = MediaArtworkSource(itemID: itemID, type: type, tag: tag, index: index)
            if source.isValid && !sources.contains(source) { sources.append(source) }
        }
        func appendBackdrop(_ owner: String?, _ tags: [String]) {
            guard let owner else { return }
            var count = 0
            for (index, tag) in tags.enumerated() {
                let source = MediaArtworkSource(itemID: owner, type: .backdrop, tag: tag, index: index)
                if source.isValid {
                    append(owner, .backdrop, tag, index: index)
                    count += 1
                    if count == 3 { break }
                }
            }
        }
        appendBackdrop(id, backdropImageTags)
        append(id, .thumb, imageTags["Thumb"])
        if let ratio = primaryImageAspectRatio, ratio.isFinite, ratio >= 1.33 {
            append(id, .primary, imageTags["Primary"])
        }
        appendBackdrop(parentBackdropItemID, parentBackdropImageTags)
        append(parentThumbItemID, .thumb, parentThumbImageTag)
        append(seriesID, .thumb, seriesThumbImageTag)
        return sources
    }
}
