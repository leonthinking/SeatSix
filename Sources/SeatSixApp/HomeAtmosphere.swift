import Accelerate
import AppKit
import CryptoKit
import SwiftUI
import SeatSixCore

/// Artwork may only tint the home that supplied it. The revision also invalidates
/// a previously accepted image when credentials or certificate trust are revoked.
struct HomeArtworkScope: Equatable {
    let connectionID: UUID
    let serverID: String
    let userID: String
    let baseURL: String
    let libraryID: String
    let posterRevision: UUID

    @MainActor init?(model: ApplicationModel, requiresLibrary: Bool = true) {
        guard let connection = model.connection, !requiresLibrary || !model.selectedLibraryID.isEmpty else { return nil }
        self.init(connectionID: connection.id, serverID: connection.serverID, userID: connection.userID,
                  baseURL: connection.baseURL.absoluteString, libraryID: model.selectedLibraryID,
                  posterRevision: model.posterRevision)
    }

    init(connectionID: UUID, serverID: String, userID: String, baseURL: String,
         libraryID: String, posterRevision: UUID) {
        self.connectionID = connectionID; self.serverID = serverID; self.userID = userID
        self.baseURL = baseURL; self.libraryID = libraryID; self.posterRevision = posterRevision
    }

    func sharesArtworkAccess(with other: Self?) -> Bool {
        guard let other else { return false }
        return connectionID == other.connectionID && serverID == other.serverID &&
            userID == other.userID && baseURL == other.baseURL && posterRevision == other.posterRevision
    }
}

/// The visible hero and its prepared background share one downloaded image.
struct HomeArtworkSnapshot: Equatable {
    struct ImageID: Equatable {
        let scope: HomeArtworkScope
        let itemID: String
        let size: CGSize
        let pixels: SHA256.Digest
    }

    let imageID: ImageID
    let accessRevision: UUID
    let requestKey: String
    let image: NSImage
    let blurredBackground: NSImage
    var selectionID: UUID?
    var scope: HomeArtworkScope { imageID.scope }
    var itemID: String { imageID.itemID }

    static func make(scope: HomeArtworkScope?, itemID: String, requestKey: String,
                     loadedKey: String?, image: NSImage?, accessRevision: UUID) -> Self? {
        guard let scope, !itemID.isEmpty, !requestKey.isEmpty, loadedKey == requestKey,
              let image, let backdrop = HomeAtmosphereArtwork.thumbnail(from: image),
              let bitmap = backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixels = bitmap.dataProvider?.data,
              let blurredBackground = HomeAtmosphereArtwork.blurredBackground(from: backdrop) else { return nil }
        // The request also lists fallback images which may never have been
        // displayed. Identify the picture by the bounded thumbnail we sampled.
        let imageID = ImageID(scope: scope, itemID: itemID, size: backdrop.size, pixels: SHA256.hash(data: pixels as Data))
        return Self(imageID: imageID, accessRevision: accessRevision, requestKey: requestKey,
                    image: backdrop, blurredBackground: blurredBackground)
    }

    func matches(scope current: HomeArtworkScope?) -> Bool { scope == current }
    func isCurrent(requestKey currentKey: String, scope currentScope: HomeArtworkScope?) -> Bool {
        requestKey == currentKey && matches(scope: currentScope)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.accessRevision == rhs.accessRevision && lhs.itemID == rhs.itemID &&
            lhs.requestKey == rhs.requestKey && lhs.image === rhs.image && lhs.selectionID == rhs.selectionID
    }
}

struct HomeArtworkPreferenceKey: PreferenceKey {
    static var defaultValue: HomeArtworkSnapshot? = nil
    static func reduce(value: inout HomeArtworkSnapshot?, nextValue: () -> HomeArtworkSnapshot?) {
        // Only the current hero opts in; unrelated posters contribute nil.
        if let next = nextValue() { value = next }
    }
}

enum HomeAtmosphereArtwork {
    static let maximumDimension = 160

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    static func thumbnail(from image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, Double(maximumDimension) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
    }

    private static func gaussianKernel(pixels: Int, displayedPoints: CGFloat) -> [Float] {
        let sigma = 80 * Double(pixels) / displayedPoints
        let radius = Int(ceil(3 * sigma))
        let weights = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// Each axis stretches independently to the window. Blur once at the
    /// default window scale, extending edge colours to avoid dark borders.
    static func blurredBackground(from thumbnail: NSImage) -> NSImage? {
        guard let source = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0, max(source.width, source.height) <= maximumDimension else { return nil }
        let width = source.width, height = source.height
        let size = CGSize(width: width, height: height)
        guard let input = bitmap(width: width, height: height), let inputData = input.data,
              let output = bitmap(width: width, height: height), let outputData = output.data else { return nil }
        input.draw(source, in: CGRect(origin: .zero, size: size))
        let horizontal = gaussianKernel(pixels: width, displayedPoints: MainWindowGeometry.preferredSize.width)
        let vertical = gaussianKernel(pixels: height, displayedPoints: MainWindowGeometry.preferredSize.height)
        var src = vImage_Buffer(data: inputData, height: UInt(height), width: UInt(width), rowBytes: input.bytesPerRow)
        var dst = vImage_Buffer(data: outputData, height: UInt(height), width: UInt(width), rowBytes: output.bytesPerRow)
        let status = vImageSepConvolve_ARGB8888(&src, &dst, nil, 0, 0, horizontal, UInt32(horizontal.count),
                                               vertical, UInt32(vertical.count), 0, nil, vImage_Flags(kvImageEdgeExtend))
        // Both bitmaps are packed premultiplied RGBA. A transparent result
        // must leave the last successful background in place.
        let bytes = outputData.assumingMemoryBound(to: UInt8.self)
        guard status == kvImageNoError, stride(from: 3, to: width * height * 4, by: 4).contains(where: { bytes[$0] > 0 }),
              let result = output.makeImage() else { return nil }
        return NSImage(cgImage: result, size: size)
    }
}

/// Low-resolution sRGB samples retain broad bands of colour without depicting faces or text.
struct ArtworkColorSamples {
    private let width: Int
    private let height: Int
    let pixels: [SeatSixChromeRGB]
    let hasVisiblePixels: Bool
    private static let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    init?(image: NSImage, maximumDimension: Int) {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0, maximumDimension > 0 else { return nil }
        let scale = min(1, Double(maximumDimension) / Double(max(source.width, source.height)))
        width = max(1, Int((Double(source.width) * scale).rounded()))
        height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = Self.context(width: width, height: height), let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var visible = false
        var samples: [SeatSixChromeRGB] = []
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            visible = visible || alpha > 0
            // Quartz supplies premultiplied RGBA. Composite transparency on neutral grey.
            let neutral = 0.5 * (1 - alpha)
            samples.append(SeatSixChromeRGB(red: Double(bytes[index]) / 255 + neutral,
                                            green: Double(bytes[index + 1]) / 255 + neutral,
                                            blue: Double(bytes[index + 2]) / 255 + neutral))
        }
        hasVisiblePixels = visible
        pixels = samples
    }

    func image(mapping: (SeatSixChromeRGB) -> SeatSixChromeRGB) -> NSImage? {
        guard let context = Self.context(width: width, height: height), let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for (offset, pixel) in pixels.enumerated() {
            let color = mapping(pixel)
            let index = offset * 4
            bytes[index] = UInt8(color.red * 255)
            bytes[index + 1] = UInt8(color.green * 255)
            bytes[index + 2] = UInt8(color.blue * 255)
            bytes[index + 3] = 255
        }
        guard let field = context.makeImage() else { return nil }
        return NSImage(cgImage: field, size: NSSize(width: width, height: height))
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: width * 4, space: space, bitmapInfo: format)
    }
}

struct HomeAtmospherePolicy: Equatable {
    let showsArtwork: Bool
    let allowsAnimation: Bool
    init(reduceTransparency: Bool, increasedContrast: Bool, reduceMotion: Bool) {
        showsArtwork = !reduceTransparency && !increasedContrast
        allowsAnimation = !reduceMotion && showsArtwork
    }
}

struct HomeAtmosphereBackground: View {
    let blurredBackground: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var policy: HomeAtmospherePolicy {
        HomeAtmospherePolicy(reduceTransparency: reduceTransparency,
                             increasedContrast: contrast == .increased, reduceMotion: reduceMotion)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SeatSixStyle.background
                if policy.showsArtwork, let blurredBackground {
                    Image(nsImage: blurredBackground).resizable().interpolation(.high)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                        }
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: SeatSixStyle.background.opacity(0), location: 0),
                                .init(color: SeatSixStyle.background.opacity(0.52), location: 0.4),
                                .init(color: SeatSixStyle.background, location: 0.82)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .id(ObjectIdentifier(blurredBackground))
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        // A missing/invalidated scope clears immediately. Only a newly accepted
        // image fades in; old-account images never linger in an exit transition.
        .animation(blurredBackground != nil && policy.allowsAnimation ? .easeInOut(duration: 0.3) : nil,
                   value: blurredBackground.map(ObjectIdentifier.init))
        .transaction { transaction in
            if blurredBackground == nil || !policy.allowsAnimation {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
