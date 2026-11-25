import AppKit
import SwiftUI
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

@MainActor
final class SettingsViewTests: XCTestCase {
    func testNativeSettingsTabsKeepParentTitleWhenSelectingCategories() async throws {
        _ = NSApplication.shared
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for page in SettingsPage.availablePages {
            let child = NSViewController()
            child.title = page.title
            child.view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
            let item = NSTabViewItem(viewController: child)
            item.label = page.title
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        let mainWindow = NSWindow()
        mainWindow.isReleasedWhenClosed = false
        mainWindow.title = "SeatSix"
        defer { window.contentViewController = nil; window.close(); mainWindow.close() }
        XCTAssertTrue(tabs.canPropagateSelectedChildViewControllerTitle)
        let titleView = SettingsWindowTitle.TitleView()
        window.contentView?.addSubview(titleView)
        try await settle(tabs.view)
        XCTAssertFalse(tabs.canPropagateSelectedChildViewControllerTitle)
        for index in SettingsPage.availablePages.indices {
            tabs.selectedTabViewItemIndex = index
            try await settle(tabs.view)
            XCTAssertEqual(tabs.title, "设置")
            XCTAssertEqual(window.title, "设置")
            XCTAssertEqual(tabs.tabViewItems[index].label, SettingsPage.availablePages[index].title)
            XCTAssertEqual(mainWindow.title, "SeatSix")
        }
        // SwiftUI Settings also writes directly after a category switch. The
        // visible title must be corrected in that same change, without a timer.
        for page in SettingsPage.availablePages {
            window.title = page.title
            XCTAssertEqual(window.title, "设置")
            XCTAssertEqual(tabs.tabViewItems.map(\.label), SettingsPage.availablePages.map(\.title))
        }
        titleView.removeFromSuperview()
        window.title = "已脱离设置视图"
        XCTAssertEqual(window.title, "已脱离设置视图", "Detaching must remove the window observation")
        mainWindow.contentView?.addSubview(titleView)
        window.title = "原窗口"
        mainWindow.title = "新设置分类"
        XCTAssertEqual(window.title, "原窗口", "Moving the view must leave its previous window untouched")
        XCTAssertEqual(mainWindow.title, "设置")
        SettingsWindowTitle.dismantleNSView(titleView, coordinator: ())
        mainWindow.title = "SeatSix"
        XCTAssertEqual(mainWindow.title, "SeatSix", "Dismantling must release the title constraint")
    }

    func testSettingsWindowUsesParentTitleForEveryCategory() async throws {
        _ = NSApplication.shared
        let model = makeModel(storage: SettingsFixtureStorage())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        for page in SettingsPage.availablePages {
            window.contentViewController = nil
            let controller = NSHostingController(rootView: SeatSixSettingsView(model: model, initialPage: page))
            window.title = page.title
            XCTAssertEqual(window.title, page.title, "A detached settings view must not mask the next category's title test")
            window.contentViewController = controller
            try await settle(controller.view)
            XCTAssertEqual(window.title, "设置", "The category label belongs below the settings window title")
        }
    }

    func testPreferenceBindingsMergeLatestValuesAndReflectRejectedSaves() {
        let storage = SettingsFixtureStorage()
        let model = makeModel(storage: storage)
        let posters = ApplicationPreferenceBinding.value(\.posterSize, model: model)
        let recent = ApplicationPreferenceBinding.value(\.showRecentlyAdded, model: model)
        let seek = ApplicationPreferenceBinding.value(\.seekForwardSeconds, model: model)

        // These bindings were created before any of the edits. An edit from
        // another settings page must never resurrect their older snapshot.
        posters.wrappedValue = .large
        seek.wrappedValue = 30
        recent.wrappedValue = false
        XCTAssertEqual(model.applicationPreferences.posterSize, .large)
        XCTAssertEqual(model.applicationPreferences.seekForwardSeconds, 30)
        XCTAssertFalse(model.applicationPreferences.showRecentlyAdded)

        storage.failSaving = true
        posters.wrappedValue = .compact
        XCTAssertEqual(posters.wrappedValue, .large)
        XCTAssertEqual(model.applicationPreferences.seekForwardSeconds, 30)
        XCTAssertNotNil(model.preferencesError)

        storage.failSaving = false
        posters.wrappedValue = .compact
        XCTAssertEqual(posters.wrappedValue, .compact)
        XCTAssertNil(model.preferencesError)
    }

    func testHomeRecommendationBindingsKeepHiddenRotationChoiceAndOtherPreferences() {
        let storage = SettingsFixtureStorage()
        let model = makeModel(storage: storage)
        let visibility = ApplicationPreferenceBinding.value(\.showHomeRecommendations, model: model)
        let rotation = ApplicationPreferenceBinding.value(\.autoRotateHomeRecommendations, model: model)
        let seek = ApplicationPreferenceBinding.value(\.seekForwardSeconds, model: model)
        XCTAssertTrue(visibility.wrappedValue)
        XCTAssertTrue(rotation.wrappedValue)

        rotation.wrappedValue = false
        seek.wrappedValue = 30
        visibility.wrappedValue = false
        XCTAssertFalse(rotation.wrappedValue, "Hiding the banner must preserve its auto-rotation choice")
        XCTAssertEqual(model.applicationPreferences.seekForwardSeconds, 30)
        visibility.wrappedValue = true
        XCTAssertFalse(rotation.wrappedValue)
        XCTAssertEqual(model.applicationPreferences.seekForwardSeconds, 30)

        storage.failSaving = true
        rotation.wrappedValue = true
        visibility.wrappedValue = false
        XCTAssertTrue(visibility.wrappedValue)
        XCTAssertFalse(rotation.wrappedValue)
        XCTAssertEqual(storage.value.applicationPreferences, model.applicationPreferences)
        storage.failSaving = false
        rotation.wrappedValue = true
        visibility.wrappedValue = false
        XCTAssertTrue(rotation.wrappedValue, "A hidden banner must also remember an enabled rotation choice")
        let reopened = makeModel(storage: storage)
        XCTAssertFalse(reopened.applicationPreferences.showHomeRecommendations)
        XCTAssertTrue(reopened.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertEqual(reopened.applicationPreferences.seekForwardSeconds, 30)
    }

    func testPageResetPreservesOtherPagesAndSavedPersonalData() throws {
        var saved = SavedApplication()
        let connection = fixtureConnection()
        saved.connections = [connection]
        saved.selectedID = connection.id
        saved.deviceID = "settings-fixture-device"
        let film = FilmPlaybackPreferences(identity: .init(connection: connection, itemID: "film", mediaSourceID: "source"),
            subtitle: .off, presentation: .init(delaySeconds: 2, fontSize: 60, style: .boxed))
        let series = SeriesPlaybackPreferences(identity: .init(connection: connection, seriesID: "series"),
            settings: .init(introSeconds: 60, outroSeconds: 45))
        saved.playbackPreferences = [film]
        saved.seriesPlaybackPreferences = [series]
        let storage = SettingsFixtureStorage(saved)
        let model = makeModel(storage: storage)
        var custom = model.applicationPreferences
        custom.startupPage = .lastBrowsed
        custom.sidebarWidth = 300
        custom.sidebarCollapsed = true
        custom.defaultLibrarySort = .yearAscending
        custom.posterSize = .large
        custom.showRecentlyAdded = false
        custom.showHomeRecommendations = false
        custom.autoRotateHomeRecommendations = false
        custom.hideUnwatchedEpisodeOverview = true
        custom.autoPlayNextEpisode = false
        custom.rememberVolume = false
        custom.resumeRewindSeconds = 10
        custom.pauseWhenMinimized = true
        custom.seekBackwardSeconds = 60
        custom.seekForwardSeconds = 30
        custom.autoHideControls = false
        custom.controlsHideDelay = 8
        custom.timeDisplay = .remaining
        custom.playbackWindowMode = .fullScreen
        custom.keepPlaybackWindowOnTop = true
        custom.subtitleMode = .off
        custom.preferredSubtitleLanguage = .japanese
        custom.preferredAudioLanguage = .english
        custom.subtitleFontSize = 72
        custom.subtitleStyle = .yellow
        let defaults = ApplicationPreferences()

        #if SEATSIX_SYSTEM_PLAYER
        let hasDecoderSettings = false
        XCTAssertEqual(SettingsPage.availablePages, [.general, .playback, .controls])
        #else
        let hasDecoderSettings = true
        XCTAssertEqual(SettingsPage.availablePages, [.general, .playback, .controls, .subtitles])
        #endif

        for page in SettingsPage.availablePages {
            XCTAssertTrue(model.updateApplicationPreferences(custom))
            XCTAssertTrue(model.updateApplicationPreferences(page.restoringDefaults(in: model.applicationPreferences)))
            // Re-open the persisted model just as an installation with the other
            // decoder would. Both distributions read this same preference format.
            let persisted = try JSONEncoder().encode(storage.value)
            let reopened = try JSONDecoder().decode(SavedApplication.self, from: persisted)
            let actual = makeModel(storage: SettingsFixtureStorage(reopened)).applicationPreferences
            XCTAssertEqual(actual, model.applicationPreferences)
            let resetDecoderPlayback = page == .playback && hasDecoderSettings
            let resetDecoderControls = page == .controls && hasDecoderSettings
            XCTAssertEqual(actual.startupPage, page == .general ? defaults.startupPage : custom.startupPage)
            XCTAssertEqual(actual.sidebarWidth, page == .general ? defaults.sidebarWidth : custom.sidebarWidth)
            XCTAssertEqual(actual.sidebarCollapsed, page == .general ? defaults.sidebarCollapsed : custom.sidebarCollapsed)
            XCTAssertEqual(actual.posterSize, page == .general ? defaults.posterSize : custom.posterSize)
            XCTAssertEqual(actual.defaultLibrarySort, page == .general ? defaults.defaultLibrarySort : custom.defaultLibrarySort)
            XCTAssertEqual(actual.showRecentlyAdded, page == .general ? defaults.showRecentlyAdded : custom.showRecentlyAdded)
            XCTAssertEqual(actual.showHomeRecommendations, page == .general ? defaults.showHomeRecommendations : custom.showHomeRecommendations)
            XCTAssertEqual(actual.autoRotateHomeRecommendations, page == .general ? defaults.autoRotateHomeRecommendations : custom.autoRotateHomeRecommendations)
            XCTAssertEqual(actual.hideUnwatchedEpisodeOverview, page == .general ? defaults.hideUnwatchedEpisodeOverview : custom.hideUnwatchedEpisodeOverview)
            XCTAssertEqual(actual.autoPlayNextEpisode, page == .playback ? defaults.autoPlayNextEpisode : custom.autoPlayNextEpisode)
            XCTAssertEqual(actual.rememberVolume, page == .playback ? defaults.rememberVolume : custom.rememberVolume)
            XCTAssertEqual(actual.resumeRewindSeconds, page == .playback ? defaults.resumeRewindSeconds : custom.resumeRewindSeconds)
            XCTAssertEqual(actual.pauseWhenMinimized, page == .playback ? defaults.pauseWhenMinimized : custom.pauseWhenMinimized)
            XCTAssertEqual(actual.seekBackwardSeconds, resetDecoderPlayback ? defaults.seekBackwardSeconds : custom.seekBackwardSeconds)
            XCTAssertEqual(actual.seekForwardSeconds, resetDecoderPlayback ? defaults.seekForwardSeconds : custom.seekForwardSeconds)
            XCTAssertEqual(actual.autoHideControls, resetDecoderControls ? defaults.autoHideControls : custom.autoHideControls)
            XCTAssertEqual(actual.controlsHideDelay, resetDecoderControls ? defaults.controlsHideDelay : custom.controlsHideDelay)
            XCTAssertEqual(actual.timeDisplay, resetDecoderControls ? defaults.timeDisplay : custom.timeDisplay)
            XCTAssertEqual(actual.playbackWindowMode, page == .controls ? defaults.playbackWindowMode : custom.playbackWindowMode)
            XCTAssertEqual(actual.keepPlaybackWindowOnTop, page == .controls ? defaults.keepPlaybackWindowOnTop : custom.keepPlaybackWindowOnTop)
            XCTAssertEqual(actual.subtitleMode, page == .subtitles ? defaults.subtitleMode : custom.subtitleMode)
            XCTAssertEqual(actual.preferredSubtitleLanguage, page == .subtitles ? defaults.preferredSubtitleLanguage : custom.preferredSubtitleLanguage)
            XCTAssertEqual(actual.preferredAudioLanguage, page == .subtitles ? defaults.preferredAudioLanguage : custom.preferredAudioLanguage)
            XCTAssertEqual(actual.subtitleFontSize, page == .subtitles ? defaults.subtitleFontSize : custom.subtitleFontSize)
            XCTAssertEqual(actual.subtitleStyle, page == .subtitles ? defaults.subtitleStyle : custom.subtitleStyle)
            XCTAssertEqual(storage.value.connections.map(\.id), [connection.id])
            XCTAssertEqual(storage.value.selectedID, connection.id)
            XCTAssertEqual(storage.value.deviceID, "settings-fixture-device")
            XCTAssertEqual(storage.value.playbackPreferences, [film])
            XCTAssertEqual(storage.value.seriesPlaybackPreferences, [series])
        }
    }

    func testLanguageBindingsKeepModeAndTrackChoicesIndependent() {
        let storage = SettingsFixtureStorage()
        let model = makeModel(storage: storage)
        let mode = ApplicationPreferenceBinding.value(\.subtitleMode, model: model)
        let subtitle = ApplicationPreferenceBinding.value(\.preferredSubtitleLanguage, model: model)
        let audio = ApplicationPreferenceBinding.value(\.preferredAudioLanguage, model: model)
        subtitle.wrappedValue = .japanese
        audio.wrappedValue = .english
        XCTAssertEqual(mode.wrappedValue, .mediaDefault, "Changing a preferred language must not silently replace media-default mode")
        mode.wrappedValue = .preferredLanguage
        XCTAssertEqual(subtitle.wrappedValue, .japanese)
        mode.wrappedValue = .off
        XCTAssertEqual(subtitle.wrappedValue, .japanese)
        XCTAssertEqual(audio.wrappedValue, .english)
        audio.wrappedValue = nil
        XCTAssertNil(storage.value.applicationPreferences.preferredAudioLanguage)
        XCTAssertEqual(storage.value.applicationPreferences.subtitleMode, .off)
    }

    func testEverySettingsPageFitsItsWindowIncludingSaveError() async throws {
        _ = NSApplication.shared
        let storage = SettingsFixtureStorage()
        let model = makeModel(storage: storage)
        var languagePreferences = model.applicationPreferences
        languagePreferences.subtitleMode = .preferredLanguage
        languagePreferences.preferredAudioLanguage = .cantonese
        XCTAssertTrue(model.updateApplicationPreferences(languagePreferences))
        let size = NSSize(width: 620, height: 500)
        for page in SettingsPage.availablePages {
            let host = makeHost(SeatSixSettingsView(model: model, initialPage: page), size: size)
            defer { host.window.contentViewController = nil; host.window.close() }
            for failed in [false, true] {
                storage.failSaving = failed
                var changed = model.applicationPreferences
                changed.showRecentlyAdded.toggle()
                _ = model.updateApplicationPreferences(changed)
                try await settle(host.controller.view)
                let fitting = host.controller.sizeThatFits(in: size)
                XCTAssertLessThanOrEqual(fitting.width, size.width + 1)
                XCTAssertLessThanOrEqual(fitting.height, size.height + 1)
                for scroll in scrollViews(in: host.controller.view) {
                    guard let document = scroll.documentView else { continue }
                    XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                             "Settings controls must fit without horizontal clipping")
                }
                try savePreviewIfRequested(host.controller.view, name: "settings-\(page.rawValue)\(failed ? "-error" : "")")
            }
        }
    }

    func testSettingsEntryIsAvailableWithoutAConnection() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let model = makeModel(storage: SettingsFixtureStorage())
        XCTAssertNil(model.connection)
        let host = makeHost(SeatSixRootView(model: model), size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        host.window.orderFront(nil)
        try await settle(host.controller.view)
        let identifiers = accessibilityIdentifiers(in: host.controller.view)
        XCTAssertTrue(identifiers.contains("navigation-home"))
        XCTAssertTrue(identifiers.contains("navigation-settings"))
    }

    func testHidingRecentItemsClampsHomeReturnPosition() async throws {
        _ = NSApplication.shared
        let connection = fixtureConnection()
        var saved = SavedApplication()
        saved.connections = [connection]; saved.selectedID = connection.id
        let model = makeModel(storage: SettingsFixtureStorage(saved))
        model.libraries = try JSONDecoder().decode([MediaLibrary].self,
            from: Data(#"[{"Id":"movies","Name":"合成电影","CollectionType":"movies"}]"#.utf8))
        model.selectedLibraryID = "movies"
        model.items = try (0..<24).map { index in
            try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: [
                "Id": "settings-movie-\(index)", "Name": "合成影片 \(index)", "Type": "Movie",
                "DateCreated": "2026-10-24T12:00:00Z", "UserData": ["PlaybackPositionTicks": 120000000]
            ]))
        }
        model.continuing = Array(model.items.prefix(3))
        model.total = model.items.count
        let host = makeHost(SeatSixRootView(model: model), size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        try await settle(host.controller.view)
        let candidates = scrollViews(in: host.controller.view).filter {
            $0.contentView.bounds.width > 500 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 50
        }
        let home = try XCTUnwrap(candidates.min { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let oldMaximum = try XCTUnwrap(home.documentView).bounds.height - home.contentView.bounds.height
        XCTAssertGreaterThan(oldMaximum, 50)
        home.contentView.scroll(to: NSPoint(x: 0, y: oldMaximum))
        home.reflectScrolledClipView(home.contentView)
        try await settle(host.controller.view)
        model.detail = model.items[0]
        try await settle(host.controller.view)
        ApplicationPreferenceBinding.value(\.showRecentlyAdded, model: model).wrappedValue = false
        model.dismissDetail()
        try await settle(host.controller.view)
        try await Task.sleep(for: .milliseconds(150))
        let newMaximum = max(0, try XCTUnwrap(home.documentView).bounds.height - home.contentView.bounds.height)
        XCTAssertLessThan(newMaximum, oldMaximum)
        XCTAssertGreaterThanOrEqual(home.contentView.bounds.origin.y, 0)
        XCTAssertLessThanOrEqual(home.contentView.bounds.origin.y, newMaximum + 1)
    }

    private func fixtureConnection() -> ServerConnection {
        ServerConnection(kind: .emby, name: "设置验收", baseURL: URL(string: "https://never-request.invalid")!,
                         serverID: "fixture", userID: "fixture", username: "fixture", libraryIDs: ["movies"])
    }

    private func makeModel(storage: SettingsFixtureStorage) -> ApplicationModel {
        ApplicationModel(storage: storage,
            credentials: CredentialAccess(read: { _ in throw ApplicationPersistenceError.unavailable }, save: { _, _ in }, remove: { _ in }),
            subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("seatsix-settings-unused-\(UUID().uuidString)", isDirectory: true)))
    }

    private func makeHost<V: View>(_ view: V, size: NSSize) -> (controller: NSHostingController<AnyView>, window: NSWindow) {
        let controller = NSHostingController(rootView: AnyView(view.preferredColorScheme(.dark)
            .tint(SeatSixStyle.accent).transaction { $0.disablesAnimations = true }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        return (controller, window)
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func accessibilityIdentifiers(in view: NSView) -> Set<String> {
        var visited: Set<ObjectIdentifier> = []
        var identifiers: Set<String> = []
        func walk(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            // SwiftUI exposes hosted accessibility nodes through AppKit selectors.
            // Some of those nodes do not declare NSAccessibilityProtocol conformance.
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = element.value(forKey: "accessibilityIdentifier") as? String {
                identifiers.insert(identifier)
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                children.forEach(walk)
            }
        }
        walk(view)
        return identifiers
    }

    private func savePreviewIfRequested(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SEATSIX_UI_PREVIEW_DIRECTORY"], directory.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}

private final class SettingsFixtureStorage: ApplicationPersisting {
    var value: SavedApplication
    var failSaving = false
    init(_ value: SavedApplication = SavedApplication()) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws {
        if failSaving { throw ApplicationPersistenceError.saveFailed }
        value = data
    }
}
