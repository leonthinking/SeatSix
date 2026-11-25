import SwiftUI
import SeatSixCore

enum SeatSixSidebarMetrics {
    static let width: CGFloat = 192
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 4
    static let horizontalInset: CGFloat = 8
    static let iconWidth: CGFloat = 18
    static let titlebarHeight: CGFloat = 52
}

/// Library navigation follows the server's actual names and identities. Two
/// movie libraries remain two destinations rather than a fabricated category.
struct SeatSixSidebarLibraryDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String

    init(_ library: MediaLibrary) {
        id = library.id
        title = library.name
        switch library.collectionType?.lowercased() {
        case "tvshows": icon = "tv"
        case "movies": icon = "film"
        default: icon = "folder"
        }
    }

    func isSelected(page: String, libraryID: String) -> Bool {
        page == "library" && libraryID == id
    }
}

/// Geometry is reported from the actual controls so layout checks do not depend
/// on offscreen accessibility exposure or assume the old floating-card gutters.
struct SeatSixSidebarFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct SeatSixSidebarGeometry: View {
    let id: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SeatSixSidebarFrameKey.self, value: [id: geometry.frame(in: .global)])
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SeatSixSidebarAppearancePolicy: Equatable {
    let isOpaque: Bool
    let emphasizesBoundary: Bool
    let allowsAnimation: Bool

    init(reduceTransparency: Bool, increasedContrast: Bool, reduceMotion: Bool) {
        isOpaque = reduceTransparency || increasedContrast
        emphasizesBoundary = increasedContrast
        allowsAnimation = !reduceMotion
    }
}

/// Destination selection and the current server communicate different things:
/// the former is where the user is, the latter is the context being browsed.
enum SeatSixSidebarRowRole: Equatable {
    case destination, connection, action
}

struct SeatSixSidebarRowPresentation: Equatable {
    let fillOpacity: Double
    let boundaryOpacity: Double
    let focusOpacity: Double
    let textOpacity: Double
    let accentOpacity: Double
    let allowsAnimation: Bool

    init(role: SeatSixSidebarRowRole, selected: Bool, hovered: Bool, pressed: Bool,
         focused: Bool, isActive: Bool, policy: SeatSixSidebarAppearancePolicy) {
        let base: Double = selected ? (role == .destination ? 0.14 : 0.044) : 0
        // Leave room for actual antialiased glyphs, not just ideal white text,
        // when a selected row is pressed over the brightest allowed field.
        let interaction: Double = pressed ? 0.07 : (hovered ? 0.045 : 0)
        fillOpacity = (base + interaction) * (isActive ? 1 : 0.72)
        boundaryOpacity = policy.emphasizesBoundary && (selected || hovered || pressed) ? 0.58 : 0
        // Focus is an outline, independent of hover/press/selection fill. It
        // remains visible on an already selected destination.
        focusOpacity = focused ? (isActive ? 0.90 : 0.70) : 0
        textOpacity = isActive ? (selected && role == .destination ? 0.98 : 0.92) : 0.88
        accentOpacity = isActive ? 1 : 0.74
        allowsAnimation = policy.allowsAnimation
    }
}

/// Row states sit above the sidebar's own contrast backing.
struct SeatSixSidebarRowBackground: View {
    let presentation: SeatSixSidebarRowPresentation

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(presentation.fillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(presentation.boundaryOpacity), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SeatSixChrome.accent.opacity(presentation.focusOpacity), lineWidth: 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SeatSixSidebarRowStyle: ButtonStyle {
    var role: SeatSixSidebarRowRole = .action
    let selected: Bool
    let focused: Bool
    let isActive: Bool
    let policy: SeatSixSidebarAppearancePolicy

    func makeBody(configuration: Configuration) -> some View {
        SeatSixSidebarRowSurface(label: configuration.label, role: role, selected: selected,
                                 pressed: configuration.isPressed, focused: focused,
                                 isActive: isActive, policy: policy)
    }
}

private struct SeatSixSidebarRowSurface<Label: View>: View {
    let label: Label
    let role: SeatSixSidebarRowRole
    let selected: Bool
    let pressed: Bool
    let focused: Bool
    let isActive: Bool
    let policy: SeatSixSidebarAppearancePolicy
    @State private var hovered = false

    private var presentation: SeatSixSidebarRowPresentation {
        .init(role: role, selected: selected, hovered: hovered, pressed: pressed,
              focused: focused, isActive: isActive, policy: policy)
    }

    var body: some View {
        label
            .background(SeatSixSidebarRowBackground(presentation: presentation))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(presentation.allowsAnimation ? .easeOut(duration: 0.12) : nil, value: hovered)
            .animation(presentation.allowsAnimation ? .easeOut(duration: 0.08) : nil, value: pressed)
            .animation(presentation.allowsAnimation ? .easeOut(duration: 0.12) : nil, value: focused)
    }
}

enum SidebarSection {
    case media, libraries, servers
}

@Observable
final class SidebarDisclosure {
    private var collapsed: Set<SidebarSection> = []

    func isExpanded(_ section: SidebarSection) -> Bool { !collapsed.contains(section) }

    func toggle(_ section: SidebarSection) {
        if collapsed.remove(section) == nil { collapsed.insert(section) }
    }
}

struct SeatSixSidebar: View {
    @ObservedObject var model: ApplicationModel
    private let appearanceOverride: SeatSixSidebarAppearancePolicy?
    private let width: CGFloat
    @State private var disclosure: SidebarDisclosure
    @State private var listHeight: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var focusedRow: String?

    init(model: ApplicationModel, appearanceOverride: SeatSixSidebarAppearancePolicy? = nil,
         width: CGFloat = SeatSixSidebarMetrics.width, disclosure: SidebarDisclosure = SidebarDisclosure()) {
        _disclosure = State(initialValue: disclosure)
        self.model = model
        self.appearanceOverride = appearanceOverride
        self.width = width.isFinite ? max(0, width) : SeatSixSidebarMetrics.width
    }

    private var appearancePolicy: SeatSixSidebarAppearancePolicy {
        appearanceOverride ?? .init(reduceTransparency: reduceTransparency,
                                    increasedContrast: contrast == .increased, reduceMotion: reduceMotion)
    }

    private var surfacePolicy: SeatSixSurfacePolicy {
        .init(reduceTransparency: appearancePolicy.isOpaque,
              increasedContrast: appearancePolicy.emphasizesBoundary,
              reduceMotion: !appearancePolicy.allowsAnimation, isActive: isActive)
    }

    private var isActive: Bool { controlActiveState != .inactive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigationAndSources
                .padding(.top, SeatSixSidebarMetrics.titlebarHeight)

            VStack(spacing: SeatSixSidebarMetrics.rowSpacing) {
                navigation("管理服务器", icon: "externaldrive.connected.to.line.below", destination: "servers")
                SettingsLink {
                    rowLabel("设置", icon: "gearshape")
                }
                .buttonStyle(rowStyle(focusID: "settings"))
                .focused($focusedRow, equals: "settings")
                .focusEffectDisabled()
                .accessibilityIdentifier("navigation-settings")
                .help("打开 SeatSix 设置（⌘,）")
                .background(SeatSixSidebarGeometry(id: "navigation-settings"))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(SeatSixSidebarGeometry(id: "footer"))
        }
        .padding(.horizontal, SeatSixSidebarMetrics.horizontalInset)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(SeatSixChrome.primaryText)
        .background {
            Color.clear
                .seatSixSurface(role: .navigation, cornerRadius: 0, policyOverride: surfacePolicy)
                .background(SeatSixSidebarGeometry(id: "sidebar-surface"))
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .background(SeatSixSidebarGeometry(id: "sidebar"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }

    var libraryDestinations: [SeatSixSidebarLibraryDestination] {
        model.libraries.map(SeatSixSidebarLibraryDestination.init)
    }

    private var navigationAndSources: some View {
        let pendingLibraryCount = model.libraries.isEmpty && model.libraryListPending
            ? Set(model.connection?.libraryIDs ?? []).count : 0
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SeatSixSidebarMetrics.rowSpacing) {
                    groupHeading("媒体库", icon: "play.rectangle", id: "media-header", section: .media)
                    if disclosure.isExpanded(.media) {
                        navigation("首页", icon: "house", destination: "home")
                        navigation("继续观看", icon: "clock.arrow.circlepath", destination: "continuing")
                        navigation("最近添加", icon: "plus.square.on.square", destination: "recent")
                        navigation("全部电影", icon: "film", destination: "movies")
                        navigation("全部剧集", icon: "tv", destination: "series")
                        navigation("其他视频", icon: "ellipsis.circle", destination: "other")
                        navigation("浏览片库", icon: "rectangle.stack", destination: "library",
                                   selected: model.page == "library" && !model.libraries.contains { $0.id == model.selectedLibraryID })
                    }

                    if !model.libraries.isEmpty || pendingLibraryCount > 0 {
                        groupHeading("服务器片库", icon: "folder", id: "libraries-header", section: .libraries)
                        if disclosure.isExpanded(.libraries) {
                            ForEach(libraryDestinations) { library($0) }
                            ForEach(0..<pendingLibraryCount, id: \.self) { _ in
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 3).frame(width: SeatSixSidebarMetrics.iconWidth, height: 14)
                                    Capsule().frame(width: 62, height: 8)
                                }
                                .foregroundStyle(SeatSixChrome.secondaryText.opacity(0.24))
                                .padding(.horizontal, 11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: SeatSixSidebarMetrics.rowHeight)
                                .accessibilityHidden(true).allowsHitTesting(false)
                            }
                        }
                    }

                    groupHeading("影视服务器", icon: "externaldrive", id: "source-header", section: .servers)
                    if disclosure.isExpanded(.servers) {
                        ForEach(model.saved.connections) { server($0) }
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // Hug short lists. Long lists share the space above the pinned
            // actions even if a section changes height while scrolled.
            .frame(maxHeight: listHeight)
            .layoutPriority(1)
            .accessibilityIdentifier("sidebar-navigation")
            .background(SeatSixSidebarGeometry(id: "server-scroll"))

            Button {
                model.reauthenticate = nil
                model.showLogin = true
            } label: {
                rowLabel("添加服务器", icon: "plus")
            }
            .buttonStyle(rowStyle(focusID: "add-server"))
            .focused($focusedRow, equals: "add-server")
            .focusEffectDisabled()
            .accessibilityIdentifier("sidebar-add-server")
            .background(SeatSixSidebarGeometry(id: "add-server"))
            .padding(.top, SeatSixSidebarMetrics.rowSpacing)

            Spacer(minLength: 0)
        }
    }

    private func groupHeading(_ title: String, icon: String, id: String, section: SidebarSection) -> some View {
        let expanded = disclosure.isExpanded(section)
        return Button {
            withAnimation(appearancePolicy.allowsAnimation ? .easeInOut(duration: 0.18) : nil) {
                disclosure.toggle(section)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: SeatSixSidebarMetrics.iconWidth)
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SeatSixChrome.tertiaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SeatSixSidebarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(rowStyle(focusID: id))
        .focused($focusedRow, equals: id)
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
        .background(SeatSixSidebarGeometry(id: id))
    }

    private func navigation(_ title: String, icon: String, destination: String, selected: Bool? = nil) -> some View {
        let selected = selected ?? (model.page == destination)
        return Button {
            model.navigate(to: destination)
        } label: {
            rowLabel(title, icon: icon, selected: selected,
                     selectionID: "navigation-selection-\(destination)")
        }
        .buttonStyle(rowStyle(role: .destination, selected: selected, focusID: "navigation-\(destination)"))
        .focused($focusedRow, equals: "navigation-\(destination)")
        .focusEffectDisabled()
        .accessibilityIdentifier("navigation-\(destination)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .background(SeatSixSidebarGeometry(id: "navigation-\(destination)"))
    }

    private func library(_ destination: SeatSixSidebarLibraryDestination) -> some View {
        let selected = destination.isSelected(page: model.page, libraryID: model.selectedLibraryID)
        return Button {
            model.navigate(to: "library", libraryID: destination.id)
        } label: {
            rowLabel(destination.title, icon: destination.icon, selected: selected,
                     selectionID: "library-selection-\(destination.id)")
        }
        .buttonStyle(rowStyle(role: .destination, selected: selected, focusID: "library-\(destination.id)"))
        .focused($focusedRow, equals: "library-\(destination.id)")
        .focusEffectDisabled()
        .accessibilityIdentifier("sidebar-library-\(destination.id)")
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("浏览 \(destination.title)")
        .background(SeatSixSidebarGeometry(id: "library-\(destination.id)"))
    }

    private func server(_ connection: ServerConnection) -> some View {
        let selected = model.connection?.id == connection.id
        return Button {
            model.switchConnection(connection.id)
        } label: {
            rowLabel(connection.name, icon: nil,
                     selected: selected, role: .connection, selectionID: "selected-indicator-\(connection.id.uuidString)")
        }
        .buttonStyle(rowStyle(role: .connection, selected: selected, focusID: "server-\(connection.id.uuidString)"))
        .focused($focusedRow, equals: "server-\(connection.id.uuidString)")
        .focusEffectDisabled()
        .accessibilityIdentifier("sidebar-server-\(connection.id.uuidString)")
        .accessibilityLabel(connection.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("切换到 \(connection.name)")
        .background(SeatSixSidebarGeometry(id: "server-\(connection.id.uuidString)"))
    }

    private func rowStyle(role: SeatSixSidebarRowRole = .action, selected: Bool = false,
                          focusID: String) -> SeatSixSidebarRowStyle {
        .init(role: role, selected: selected, focused: focusedRow == focusID,
              isActive: isActive, policy: appearancePolicy)
    }

    private func rowLabel(_ title: String, icon: String?, selected: Bool = false,
                          role: SeatSixSidebarRowRole = .destination, selectionID: String? = nil) -> some View {
        let presentation = SeatSixSidebarRowPresentation(role: role, selected: selected, hovered: false,
            pressed: false, focused: false, isActive: isActive, policy: appearancePolicy)
        return HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: SeatSixSidebarMetrics.iconWidth)
                    .foregroundStyle(selected && role == .destination
                                     ? SeatSixChrome.accent.opacity(presentation.accentOpacity)
                                     : SeatSixChrome.secondaryText)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: SeatSixSidebarMetrics.iconWidth, height: 1)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 13, weight: selected && role == .destination ? .medium : .regular))
                .foregroundStyle(Color.white.opacity(presentation.textOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SeatSixSidebarMetrics.rowHeight)
        .overlay(alignment: .leading) {
            if selected, let selectionID {
                Capsule().fill(SeatSixChrome.accent.opacity(presentation.accentOpacity))
                    .frame(width: role == .connection ? 3 : 2, height: role == .connection ? 16 : 14)
                    .background(SeatSixSidebarGeometry(id: selectionID))
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
