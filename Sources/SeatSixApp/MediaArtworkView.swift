import AppKit
import ImageIO
import SwiftUI
import SeatSixCore

actor PosterRequestGate {
    static let shared = PosterRequestGate()
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }
    init(limit: Int = 4) { self.limit = max(1, limit) }
    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

@MainActor
final class PosterCache {
    static let shared = PosterCache()
    private let cache = NSCache<NSString, NSImage>()
    private var connectionGenerations: [String: UUID] = [:]
    private let gate: PosterRequestGate
    init(gate: PosterRequestGate = .shared) {
        self.gate = gate
        cache.countLimit = 100; cache.totalCostLimit = 80 * 1024 * 1024
    }
    func remove(connectionID: UUID) {
        let id = connectionID.uuidString
        connectionGenerations[id] = UUID()
        // Revocation is infrequent. Clearing this bounded cache avoids retaining an unbounded
        // index of every image key ever seen after NSCache has already evicted the image.
        cache.removeAllObjects()
    }
    func load(key: String, item: MediaItem, client: MediaServerClient,
              role: MediaArtworkRole = .poster, requestWidth: Int = 600) async -> NSImage? {
        await load(key: key, sources: item.artworkSources(for: role), client: client,
                   role: role, requestWidth: requestWidth)
    }

    func load(key: String, sources: [MediaArtworkSource], client: MediaServerClient,
              role: MediaArtworkRole, requestWidth: Int) async -> NSImage? {
        let width = role.boundedWidth(requestWidth)
        guard !sources.isEmpty, !Task.isCancelled else { return nil }
        let connection = client.connection
        let connectionID = connection.id.uuidString
        let generation = connectionGenerations[connectionID]
        // Keep role, size and identity in the cache even if a caller reuses its local key.
        let cacheKey = String(reflecting: [key, connectionID, connection.serverID, connection.userID,
            connection.baseURL.absoluteString, role.rawValue, String(width),
            String(reflecting: sources.map(\.cacheComponents))]) as NSString
        if let found = cache.object(forKey: cacheKey) { return found }
        await gate.acquire()
        let image = await loadAcquired(sources: sources, client: client, role: role, width: width,
                                       connectionID: connectionID, generation: generation)
        await gate.release()
        guard !Task.isCancelled, connectionGenerations[connectionID] == generation, let image else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: cacheKey, cost: cost)
        return image
    }

    private func loadAcquired(sources: [MediaArtworkSource], client: MediaServerClient,
                              role: MediaArtworkRole, width: Int,
                              connectionID: String, generation: UUID?) async -> NSImage? {
        for artwork in sources {
            // Revocation and cancellation also gate each fallback request.
            guard !Task.isCancelled, connectionGenerations[connectionID] == generation else { return nil }
            let data: Data
            do {
                guard let loaded = try await client.imageData(source: artwork, width: width, role: role) else { continue }
                data = loaded
            } catch MediaServerError.httpStatus(let status) where status == 404 || status == 410 {
                continue
            } catch { return nil }
            guard !Task.isCancelled, connectionGenerations[connectionID] == generation else { return nil }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: width,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { continue }
            // Some compatible servers mislabel images. Never crop an actual portrait
            // into a landscape slot merely because its metadata said Backdrop/Thumb.
            if role.isLandscape && Double(thumbnail.width) / Double(thumbnail.height) < 1.33 { continue }
            if role == .logo && !Self.logoIsReadableOnDarkSurface(thumbnail) { continue }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
        return nil
    }

    // A dark wordmark on the dark footer can disappear just as completely as an
    // empty PNG. Check a small, fixed-size sample before replacing the real title.
    private static func logoIsReadableOnDarkSurface(_ image: CGImage) -> Bool {
        let width = 80, height = 40
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var transparent = 0, visible = 0, bright = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = pixels[index + 3]
            if alpha < 32 { transparent += 1 }
            guard alpha >= 96 else { continue }
            visible += 1
            // Premultiplied color models the visible ink over a dark background.
            let color = SeatSixChromeRGB(red: Double(pixels[index]) / 255,
                                         green: Double(pixels[index + 1]) / 255,
                                         blue: Double(pixels[index + 2]) / 255)
            if color.relativeLuminance >= 0.32 { bright += 1 }
        }
        let minimumArea = width * height / 50
        return transparent >= minimumArea && visible >= minimumArea && bright * 2 >= visible
    }
}

struct MediaPoster: View {
    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    var role: MediaArtworkRole = .poster
    var requestWidth: Int = 600
    var landscapeContentMode: ContentMode = .fit
    var showsPlaceholder = true
    var reportsHomeArtwork = false
    // Preloaded and departing carousel slides keep the same request identity,
    // but only the currently displayed slide may tint the surrounding window.
    var contributesHomeArtwork = true
    @State private var image: NSImage?
    @State private var loadedKey: String?
    @State private var homeArtwork: HomeArtworkSnapshot?
    @MainActor static func requestKey(model: ApplicationModel, item: MediaItem, role: MediaArtworkRole,
                                      requestWidth: Int, libraryID: String = "") -> String {
        String(reflecting: [model.connection?.id.uuidString ?? "", model.connection?.serverID ?? "",
            model.connection?.userID ?? "", model.connection?.baseURL.absoluteString ?? "", model.posterRevision.uuidString,
            item.id, role.rawValue, String(role.boundedWidth(requestWidth)),
            libraryID,
            String(reflecting: item.artworkSources(for: role).map(\.cacheComponents))])
    }
    private var key: String {
        Self.requestKey(model: model, item: item, role: role, requestWidth: requestWidth,
                        libraryID: reportsHomeArtwork ? model.selectedLibraryID : "")
    }
    // Keep the bitmap cache key stable when another library loses access.
    // Each displayed recommendation must still report under the current grant.
    private struct LoadID: Equatable {
        let key: String
        let homeAccess: UUID?
    }
    private var loadID: LoadID {
        let allowed = reportsHomeArtwork && model.canBrowseCurrentMedia && model.selectedLibrary != nil
        return LoadID(key: key, homeAccess: allowed ? model.windowArtworkRevision : nil)
    }
    private var reportedHomeArtwork: HomeArtworkSnapshot? {
        guard reportsHomeArtwork, contributesHomeArtwork, role == .landscape,
              let homeArtwork, homeArtwork.accessRevision == loadID.homeAccess,
              homeArtwork.isCurrent(requestKey: key, scope: HomeArtworkScope(model: model)) else { return nil }
        return homeArtwork
    }
    var body: some View {
        let request = loadID
        let mayLoad = !reportsHomeArtwork || request.homeAccess != nil
        MediaPosterContent(image: mayLoad && loadedKey == request.key ? image : nil,
                           pending: mayLoad && loadedKey != request.key && model.connection != nil && !item.artworkSources(for: role).isEmpty,
                           item: item, role: role, landscapeContentMode: landscapeContentMode, showsPlaceholder: showsPlaceholder)
        .task(id: request) {
            guard !Task.isCancelled, request == loadID else { return }
            if loadedKey != request.key || !mayLoad { image = nil; loadedKey = nil }
            homeArtwork = nil
            let requestScope = HomeArtworkScope(model: model)
            guard mayLoad, !item.artworkSources(for: role).isEmpty, let connection = model.connection,
                  let client = try? model.client(for: connection) else { loadedKey = request.key; return }
            if image == nil {
                let loaded = await PosterCache.shared.load(key: request.key, item: item, client: client,
                                                           role: role, requestWidth: requestWidth)
                guard !Task.isCancelled, request == loadID else { return }
                image = loaded
            }
            loadedKey = request.key
            if let access = request.homeAccess, role == .landscape {
                homeArtwork = HomeArtworkSnapshot.make(scope: requestScope, itemID: item.id, requestKey: request.key,
                                                       loadedKey: request.key, image: image, accessRevision: access)
            }
        }
        .preference(key: HomeArtworkPreferenceKey.self, value: reportedHomeArtwork)
    }
}

struct MediaPosterContent: View {
    let image: NSImage?
    let pending: Bool
    let item: MediaItem
    var role: MediaArtworkRole = .poster
    var landscapeContentMode: ContentMode = .fit
    var showsPlaceholder = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.23), SeatSixStyle.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(nsImage: image).resizable()
                        .aspectRatio(contentMode: role.isLandscape ? landscapeContentMode : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if showsPlaceholder, pending {
                    ShelfRefreshSkeleton.fill
                        .accessibilityHidden(true)
                } else if showsPlaceholder {
                    VStack(spacing: 12) {
                        Image(systemName: "film").font(.system(size: 30, weight: .ultraLight))
                        Text(role == .landscape ? "暂无横版海报" : "暂无海报").font(.system(size: 10))
                    }.foregroundStyle(Color.white.opacity(role == .landscape ? 0.5 : 0.22))
                }
            }
        }
        .accessibilityLabel("\(item.name) 海报")
    }
}
