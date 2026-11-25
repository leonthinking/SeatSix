import AppKit
import SwiftUI
import SeatSixCore

struct DetailArtworkAppearance: Equatable {
    let colorField: NSImage?
    let isLight: Bool
    var blurredBackground: NSImage? = nil
    var hasArtwork: Bool { colorField != nil }
    static let neutral = Self(colorField: nil, isLight: false)

    static func make(from image: NSImage?) -> Self {
        guard let image, let thumbnail = HomeAtmosphereArtwork.thumbnail(from: image),
              let samples = ArtworkColorSamples(image: thumbnail, maximumDimension: 8),
              samples.hasVisiblePixels else { return .neutral }
        let luminance = samples.pixels.reduce(0) { $0 + $1.relativeLuminance } / Double(samples.pixels.count)
        let isLight = luminance >= 0.19
        guard let field = samples.image(mapping: isLight ? lightBackground : darkBackground) else { return .neutral }
        return Self(colorField: field, isLight: isLight,
                    blurredBackground: HomeAtmosphereArtwork.blurredBackground(from: thumbnail))
    }

    func applying(_ policy: HomeAtmospherePolicy) -> Self {
        policy.showsArtwork ? self : .neutral
    }

    private static func lightBackground(_ sample: SeatSixChromeRGB) -> SeatSixChromeRGB {
        // A minimum weighted sRGB brightness is preserved by interpolation. It
        // therefore protects dark labels even between two very different hues.
        let luma = 0.2126 * sample.red + 0.7152 * sample.green + 0.0722 * sample.blue
        guard luma < 0.63 else { return sample }
        let white = (0.63 - luma) / (1 - luma)
        return SeatSixChromeRGB(red: sample.red + (1 - sample.red) * white,
                                green: sample.green + (1 - sample.green) * white,
                                blue: sample.blue + (1 - sample.blue) * white)
    }

    private static func darkBackground(_ sample: SeatSixChromeRGB) -> SeatSixChromeRGB {
        // Scaling linear light preserves hue and sets an explicit luminance
        // ceiling for light text across the entire field, including bright patches.
        sample.limitingLuminance(to: 0.095)
    }
}

struct DetailArtwork {
    let poster: NSImage?
    let posterPending: Bool
    let landscape: NSImage?
    let appearance: DetailArtworkAppearance
    var logo: NSImage? = nil
    var landscapePending = false

    var background: some View {
        SeatSixStyle.background.overlay {
            if let field = appearance.colorField {
                // Stretch the sampled field to keep both edges visible at any pane size.
                Image(nsImage: field).resizable().interpolation(.high)
            }
        }
        .clipped().accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// The prepared thumbnail follows navigation. Keep its source to distinguish
/// a new recommendation from a detail that superseded the previous banner.
struct WindowArtworkPalette: Equatable {
    enum Source { case recommendation, detail }
    let scope: HomeArtworkScope
    let accessRevision: UUID
    let itemID: String
    let field: NSImage
    var source: Source = .detail

    @MainActor func belongsToOpenDetail(in model: ApplicationModel) -> Bool {
        model.page != "servers" && model.detail?.id == itemID && accessRevision == model.windowArtworkRevision &&
            scope == HomeArtworkScope(model: model, requiresLibrary: false)
    }
}

struct DetailWindowPaletteKey: PreferenceKey {
    static var defaultValue: WindowArtworkPalette? { nil }

    static func reduce(value: inout WindowArtworkPalette?, nextValue: () -> WindowArtworkPalette?) {
        if let next = nextValue() { value = next }
    }
}

/// The header and the full detail viewport share the artwork requested
/// here. Keeping the owner outside the header also preserves the artwork when
/// the series switches to its all-episodes presentation.
struct DetailArtworkHost<Content: View>: View {
    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    let policyOverride: HomeAtmospherePolicy?
    private let presentationScope: HomeArtworkScope?
    private let accessRevision: UUID
    @ViewBuilder var content: (DetailArtwork) -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: LoadedArtwork?
    @State private var landscape: LoadedArtwork?
    @State private var logo: LoadedArtwork?

    private struct LoadedArtwork {
        let key: String
        let image: NSImage?
        let appearance: DetailArtworkAppearance
    }

    init(model: ApplicationModel, item: MediaItem, policyOverride: HomeAtmospherePolicy? = nil,
         @ViewBuilder content: @escaping (DetailArtwork) -> Content) {
        self.model = model
        self.item = item
        self.policyOverride = policyOverride
        self.presentationScope = HomeArtworkScope(model: model, requiresLibrary: false)
        self.accessRevision = model.windowArtworkRevision
        self.content = content
    }

    private var ownsPresentation: Bool {
        accessRevision == model.windowArtworkRevision && presentationScope != nil &&
            presentationScope == HomeArtworkScope(model: model, requiresLibrary: false)
    }

    var body: some View {
        Group {
            if ownsPresentation {
                detailWithArtwork
            } else {
                // SwiftUI can retain a departing view for its removal animation.
                Color.clear.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .transaction { transaction in
            if !ownsPresentation {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var detailWithArtwork: some View {
        let policy = policyOverride ?? HomeAtmospherePolicy(reduceTransparency: reduceTransparency,
                                                             increasedContrast: contrast == .increased, reduceMotion: reduceMotion)
        let posterKey = MediaPoster.requestKey(model: model, item: item, role: .poster, requestWidth: 600)
        let landscapeWidth = MediaArtworkRole.detailBackdrop.maximumWidth
        let landscapeKey = policy.showsArtwork
            ? MediaPoster.requestKey(model: model, item: item, role: .detailBackdrop, requestWidth: landscapeWidth) : nil
        let portrait = poster?.key == posterKey ? poster : nil
        let backdrop = landscape?.key == landscapeKey ? landscape : nil
        let hasBackdrop = backdrop?.appearance.hasArtwork == true
        let appearance = ((hasBackdrop ? backdrop?.appearance : portrait?.appearance) ?? .neutral).applying(policy)
        let logoKey = hasBackdrop && !model.seriesPresentation.showsAll && !item.artworkSources(for: .logo).isEmpty
            ? MediaPoster.requestKey(model: model, item: item, role: .logo, requestWidth: 600) : nil
        return content(DetailArtwork(poster: portrait?.image,
                                     posterPending: portrait == nil && !item.artworkSources(for: .poster).isEmpty,
                                     landscape: hasBackdrop ? backdrop?.image : nil,
                                     appearance: appearance,
                                     logo: logo?.key == logoKey ? logo?.image : nil,
                                     landscapePending: policy.showsArtwork && backdrop == nil
                                        && !item.artworkSources(for: .detailBackdrop).isEmpty))
            .background {
                if let field = appearance.blurredBackground, let presentationScope, model.detail?.id == item.id {
                    Color.clear.preference(key: DetailWindowPaletteKey.self,
                        value: .init(scope: presentationScope, accessRevision: accessRevision, itemID: item.id, field: field))
                }
            }
            .task(id: posterKey) { await load(.poster, width: 600, key: posterKey) }
            .task(id: landscapeKey) {
                if let landscapeKey { await load(.detailBackdrop, width: landscapeWidth, key: landscapeKey) }
            }
            .task(id: logoKey) {
                if let logoKey { await load(.logo, width: 600, key: logoKey) }
            }
    }

    @MainActor private func load(_ role: MediaArtworkRole, width: Int, key: String) async {
        guard ownsPresentation else { return }
        var image: NSImage?
        if !item.artworkSources(for: role).isEmpty, let connection = model.connection, let client = try? model.client(for: connection) {
            image = await PosterCache.shared.load(key: key, item: item, client: client, role: role, requestWidth: width)
        }
        guard !Task.isCancelled, ownsPresentation,
              MediaPoster.requestKey(model: model, item: item, role: role, requestWidth: width) == key else { return }
        let loaded = LoadedArtwork(key: key, image: image, appearance: role == .logo ? .neutral : .make(from: image))
        switch role {
        case .poster: poster = loaded
        case .detailBackdrop, .landscape: landscape = loaded
        case .logo: logo = loaded
        }
    }
}
