import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import SeatSixCore
import SeatSixPlayback

/// An acknowledgement may confirm only the exact local snapshot that it describes.
struct PlaybackJournal {
    private(set) var revision = 0
    private(set) var ticks: Int64 = 0
    mutating func record(_ value: Int64) -> Int {
        revision += 1; ticks = max(0, value); return revision
    }
    func accepts(_ acknowledgement: Int) -> Bool { acknowledgement == revision }
}

struct PlaybackWrite: Equatable {
    enum Kind { case start, progress, stop }
    let kind: Kind
    let ticks: Int64
    let paused: Bool
    let revision: Int
}

/// Holds at most one active write and one replacement. Stop replaces any unsent progress.
@MainActor
final class PlaybackReportPump {
    typealias Sender = (PlaybackWrite) async throws -> Void
    private let send: Sender
    private let acknowledged: (PlaybackWrite) -> Void
    private let failed: () -> Void
    private var active = false
    private var pending: PlaybackWrite?
    private var started = false
    private(set) var stopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var uncertain = false
    private(set) var finished = false
    var outstandingCount: Int { (active ? 1 : 0) + (pending == nil ? 0 : 1) }

    init(send: @escaping Sender, acknowledged: @escaping (PlaybackWrite) -> Void, failed: @escaping () -> Void) {
        self.send = send; self.acknowledged = acknowledged; self.failed = failed
    }

    func start(ticks: Int64, revision: Int) {
        guard !started, !stopping, !uncertain else { return }
        started = true
        dispatch(PlaybackWrite(kind: .start, ticks: ticks, paused: false, revision: revision))
    }

    func progress(ticks: Int64, paused: Bool, revision: Int) {
        guard started, !stopping, !uncertain, !finished else { return }
        dispatch(PlaybackWrite(kind: .progress, ticks: ticks, paused: paused, revision: revision))
    }

    func stop(ticks: Int64, revision: Int) async {
        guard started, !uncertain, !finished else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
            guard !stopping else { return }
            stopping = true
            // Unsent progress carries no extra information beyond this final stop snapshot.
            pending = nil
            dispatch(PlaybackWrite(kind: .stop, ticks: ticks, paused: true, revision: revision))
        }
    }

    private func dispatch(_ write: PlaybackWrite) {
        if active { pending = write; return }
        active = true
        Task { await drain(startingWith: write) }
    }

    private func drain(startingWith initial: PlaybackWrite) async {
        var current: PlaybackWrite? = initial
        while let write = current {
            do {
                try await send(write)
                acknowledged(write)
                if write.kind == .stop { finished = true; pending = nil }
            } catch {
                uncertain = true; pending = nil
                failed()
            }
            if uncertain || finished { current = nil }
            else { current = pending; pending = nil }
        }
        active = false
        if uncertain || finished {
            let waiters = stopWaiters; stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}

/// A seek jump or a loaded-but-paused frame must not create a viewing session.
struct PlaybackStartGate {
    var baseline: Double = 0
    mutating func observe(seconds: Double, playing: Bool, seeking: Bool) -> Bool {
        guard seconds.isFinite, seconds >= 0, !seeking else { return false }
        if !playing || abs(seconds - baseline) > 3 { baseline = seconds; return false }
        return seconds > baseline + 0.05
    }
}

struct PlaybackCompletionGate {
    private(set) var endedNaturally = false
    private(set) var cancelled = false
    mutating func beginNaturalEnd(started: Bool, stopped: Bool, failed: Bool) -> Bool {
        guard started, !stopped, !failed, !endedNaturally, !cancelled else { return false }
        endedNaturally = true
        return true
    }
    mutating func cancel() { cancelled = true }
    var mayContinue: Bool { endedNaturally && !cancelled }
}

struct EpisodeRecoveryChoice {
    let localTicks: Int64
    let remoteTicks: Int64
}

extension MediaItem {
    /// A display aspect from the selected edition is useful before the first decoded frame.
    func playbackAspectRatio(for mediaSourceID: String?, fitting fits: (CGFloat) -> Bool) -> CGFloat? {
        let source: MediaSource?
        if let mediaSourceID {
            source = mediaSources.first { $0.id == mediaSourceID }
        } else {
            source = mediaSources.count == 1 ? mediaSources.first : nil
        }
        let streams: [MediaStream]
        if let source, let sourceStreams = source.mediaStreams, !sourceStreams.isEmpty {
            streams = sourceStreams
        } else if mediaSources.count <= 1, mediaSourceID == nil || mediaSources.first?.id == mediaSourceID {
            streams = mediaStreams
        } else {
            // Several editions may have different framing. Wait for the actual decoder.
            return nil
        }
        guard let video = streams.first(where: { $0.type?.lowercased() == "video" }) else { return nil }
        if let aspect = video.aspectRatio {
            let parts = aspect.components(separatedBy: CharacterSet(charactersIn: ":/"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if (1...2).contains(parts.count), let width = Double(parts[0]),
               let height = parts.count == 1 ? 1 : Double(parts[1]),
               let ratio = Self.displayRatio(width: width, height: height), fits(ratio) { return ratio }
        }
        guard let width = video.width, let height = video.height,
              let ratio = Self.displayRatio(width: CGFloat(width), height: CGFloat(height)), fits(ratio) else { return nil }
        return ratio
    }

    fileprivate static func displayRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = width / height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}

@MainActor
final class NativePlaybackController: ObservableObject {
    let item: MediaItem
    let connection: ServerConnection
    let playbackDefaults: ApplicationPreferences
    @Published private(set) var interfacePreferences: ApplicationPreferences
    @Published private(set) var isWindowOnTop = false
    var onToggleWindowOnTop: (() -> Void)?
    var onFitWindowToVideo: ((CGFloat) -> Void)?
    var onOpeningAspectRatio: ((CGFloat) -> Void)?
    var onMinimizePause: (() -> Void)?
    private var minimizePausePolicy: PlaybackMinimizePausePolicy
    let player = AVPlayer()
    @Published private(set) var localEngine: LocalPlaybackEngine?
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var isPaused = true
    @Published private(set) var isBuffering = false
    @Published private(set) var volume = 1.0
    @Published private(set) var playbackRate = 1.0
    @Published private(set) var changingPlaybackRate = false
    @Published private(set) var playbackControlMessage: String?
    @Published var autoPlayNextEpisode = true
    @Published var nextEpisodeMessage: String?
    @Published var episodeSequence: EpisodeSequence?
    @Published private(set) var switchingEpisode = false
    @Published var episodeRecoveryChoice: EpisodeRecoveryChoice?
    @Published private(set) var seriesSkipSettings = SeriesSkipSettings()
    @Published private(set) var seriesSkipMessage: String?
    private var seriesSkipAccess: SeriesPlaybackPreferencesAccess?
    private var outroSkipClaimed = false
    private var outroAdvanceGate = PlaybackStartGate()
    private var outroSkipTask: Task<Void, Never>?
    private let compatibilitySeek: (AVPlayer, Double) async -> Bool
    var canConfigureSeriesSkip: Bool { seriesSkipAccess != nil && !preparing && !stopping && !switchingEpisode }
    var onSelectEpisode: ((String, Bool) -> Void)?
    var onChooseEpisodeRecovery: ((Bool) -> Void)?
    var onCancelEpisodeRecovery: (() -> Void)?
    private var episodeSwitchID: UUID?
    var canSelectEpisode: Bool {
        item.type == "Episode" && episodeSequence != nil && !preparing && !stopping && !switchingEpisode
    }
    var onNaturalCompletion: ((NativePlaybackController) async -> Void)?
    private var completion: PlaybackCompletionGate
    var canAutomaticallyContinue: Bool { completion.mayContinue && !minimizePausePolicy.blocksAutomaticPlayback }
    private var volumeBeforeMute = 1.0
    private var initialPlaybackRate = 1.0
    private var volumeObservations: [NSKeyValueObservation] = []
    private var playbackRateObservation: NSKeyValueObservation?
    private var lastNotifiedVolume: PlaybackVolumeState?
    var onVolumeChange: ((PlaybackVolumeState) -> Void)?
    private var mediaDefaultAudioTrackID: Int?
    private var mediaDefaultSubtitleTrackID: Int?
    private var capturedMediaDefaults = false
    var followsApplicationAudio: Bool { filmPreferences?.audio == nil }
    var followsApplicationSubtitle: Bool { filmPreferences?.subtitle == nil }
    @Published private(set) var audioTracks: [LocalPlaybackTrack] = []
    @Published private(set) var subtitleTracks: [LocalPlaybackTrack] = []
    @Published private(set) var serverSubtitles: [ServerSubtitle] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?
    @Published private(set) var changingTrack = false
    @Published private(set) var trackMessage: String?
    private var trackOperation: Task<Void, Never>?
    private var importedServerTracks: [String: Int] = [:]
    private var importedLocalTracks: [Int: ArchivedSubtitle] = [:]
    var preferenceAccess: PlaybackPreferencesAccess?
    private(set) var filmPreferences: FilmPlaybackPreferences?
    @Published private(set) var subtitlePresentation = SubtitlePresentation()
    var selectedSubtitleIsBitmap: Bool {
        guard let track = subtitleTracks.first(where: { $0.id == selectedSubtitleTrackID }) else { return false }
        return ["hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvb_subtitle", "vobsub"].contains(track.codec?.lowercased() ?? "")
    }
    private var localTimer: Timer?
    private var seekingOutro = false
    @Published private(set) var manualSeekTarget: Double?
    private var manualSeekTask: Task<Void, Never>?
    private var seekingLocally: Bool { seekingOutro || manualSeekTarget != nil }
    private var startGate = PlaybackStartGate()
    @Published var preparing = true
    @Published var errorMessage: String?
    @Published var syncMessage = "等待播放"
    @Published var playbackLabel = "正在准备"
    @Published var stopping = false
    private let client: MediaServerClient
    private let save: (Int64, Bool) -> Bool
    private var plan: PlaybackPlan?
    private var playbackRelay: PinnedPlaybackRelay?
    private var reportPump: PlaybackReportPump?
    private var observer: Any?
    private var stateObservation: NSKeyValueObservation?
    private var presentationObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var stopTask: Task<Void, Never>?
    private var didStart = false
    private var stopped = false
    private var uncertain = false
    private var localSaveFailed = false
    var progressWarning: String? { uncertain || localSaveFailed ? syncMessage : nil }
    var compactProgressWarning: String { localSaveFailed ? "本机保存失败" : "仅本机保存" }
    private var pendingProgressSnapshot: Int64?
    private(set) var requestedMode: PlaybackMode = .automatic
    private(set) var requestedMediaSourceID: String?
    var isActive: Bool { !stopped && errorMessage == nil }
    private var journal = PlaybackJournal()
    private var lastReport = Date.distantPast
    private var lastPaused = false
    private var lastPosition = 0.0

    init(item: MediaItem, connection: ServerConnection, client: MediaServerClient,
         mediaSourceID: String? = nil,
         applicationPreferences: ApplicationPreferences = .init(),
         completionGate: PlaybackCompletionGate = PlaybackCompletionGate(),
         compatibilitySeek: @escaping (AVPlayer, Double) async -> Bool = { player, seconds in
             await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
         }, save: @escaping (Int64, Bool) -> Bool) {
        self.item = item; self.connection = connection; self.client = client; self.save = save
        self.requestedMediaSourceID = mediaSourceID
        let preferences = applicationPreferences.normalized
        self.playbackDefaults = preferences
        self.interfacePreferences = preferences
        self.minimizePausePolicy = PlaybackMinimizePausePolicy(enabled: preferences.pauseWhenMinimized)
        self.autoPlayNextEpisode = preferences.autoPlayNextEpisode
        self.subtitlePresentation = preferences.subtitlePresentation
        self.completion = completionGate
        self.compatibilitySeek = compatibilitySeek
        player.automaticallyWaitsToMinimizeStalling = true
        volumeObservations = [
            player.observe(\.volume, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.compatibilityVolumeChanged() }
            },
            player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.compatibilityVolumeChanged() }
            }
        ]
        lastNotifiedVolume = volumeState
        playbackRateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.compatibilityPlaybackIntentChanged() }
        }
    }

    func updateInterfacePreferences(_ preferences: ApplicationPreferences) {
        interfacePreferences = preferences.normalized
        let alreadyPaused = minimizePausePolicy.requiresExplicitResume
        minimizePausePolicy.update(enabled: interfacePreferences.pauseWhenMinimized)
        if minimizePausePolicy.blocksAutomaticPlayback { pauseForWindow() }
        if !alreadyPaused, minimizePausePolicy.requiresExplicitResume { onMinimizePause?() }
    }

    func setWindowMiniaturized(_ value: Bool) {
        // Keep the pause request even on an ended owner while next-episode
        // metadata is loading. Replacement inherits it before preparing audio.
        let alreadyPaused = minimizePausePolicy.requiresExplicitResume
        minimizePausePolicy.setMiniaturized(value)
        if minimizePausePolicy.blocksAutomaticPlayback { pauseForWindow() }
        if !alreadyPaused, minimizePausePolicy.requiresExplicitResume { onMinimizePause?() }
    }

    func inheritWindowPause(from previous: NativePlaybackController) {
        minimizePausePolicy.inheritPause(from: previous.minimizePausePolicy)
        if minimizePausePolicy.blocksAutomaticPlayback { pauseForWindow() }
    }

    func setWindowOnTop(_ value: Bool) { isWindowOnTop = value }
    func toggleWindowOnTop() { onToggleWindowOnTop?() }
    var canFitWindowToVideo: Bool {
        !preparing && !stopped && !switchingEpisode && onFitWindowToVideo != nil && localEngine?.snapshot.displayAspectRatio != nil
    }
    func fitWindowToVideo() {
        guard canFitWindowToVideo, let ratio = localEngine?.snapshot.displayAspectRatio else { return }
        onFitWindowToVideo?(ratio)
    }

    var displayedAspectRatio: CGFloat? {
        if let engine = localEngine { return engine.snapshot.displayAspectRatio.map { CGFloat($0) } }
        guard let size = player.currentItem?.presentationSize else { return nil }
        return MediaItem.displayRatio(width: size.width, height: size.height)
    }

    private func resolveOpeningAspectIfReady() {
        guard !preparing, !stopped, let deliver = onOpeningAspectRatio, let ratio = displayedAspectRatio else { return }
        onOpeningAspectRatio = nil
        deliver(ratio)
    }

    private func pauseForWindow() {
        if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
        if let engine = localEngine, !engine.snapshot.paused { engine.pause() }
        isPaused = true
    }

    /// All application-owned resumes pass this gate, including delayed loads
    /// and the completion of an outro seek.
    func resumeAutomatically() {
        guard !stopped, !preparing else { return }
        guard !minimizePausePolicy.blocksAutomaticPlayback else { pauseForWindow(); return }
        if let engine = localEngine { engine.play() } else { player.play() }
    }

    private func compatibilityPlaybackIntentChanged() {
        guard localEngine == nil, player.rate != 0 else { return }
        guard !stopped, !preparing, minimizePausePolicy.requestExplicitPlayback() else {
            if minimizePausePolicy.blocksAutomaticPlayback || stopped { pauseForWindow() }
            return
        }
        // The system AVPlayerView's Play control bypasses togglePause. Once
        // restored, that explicit action releases the same pause latch.
    }

    static func capability(for mode: PlaybackMode) -> PlaybackCapability {
        mode == .automatic && LocalPlaybackEngine.isAvailable ? .localDecoder : .avFoundation
    }

    func load(mode: PlaybackMode, mediaSourceID: String?, startTicks: Int64) async {
        requestedMode = mode; requestedMediaSourceID = mediaSourceID
        do {
            let capability = Self.capability(for: mode)
            let negotiated = try await client.playbackPlan(item: item, mediaSourceID: mediaSourceID, mode: mode, startTicks: startTicks, capability: capability)
            guard !stopped else { try? await client.stopTranscoding(plan: negotiated); return }
            plan = negotiated
            serverSubtitles = negotiated.externalSubtitles
            let reporter = PlaybackReporter(client: client, plan: negotiated)
            reportPump = PlaybackReportPump(send: { write in
                switch write.kind {
                case .start: try await reporter.start(positionTicks: write.ticks)
                case .progress: try await reporter.progress(positionTicks: write.ticks, isPaused: write.paused)
                case .stop: try await reporter.stop(positionTicks: write.ticks)
                }
            }, acknowledged: { [weak self] write in
                guard let self, self.journal.accepts(write.revision) else { return }
                if self.persistSnapshot(ticks: write.ticks, confirmed: true) { self.syncMessage = "进度已同步" }
            }, failed: { [weak self] in self?.markUncertain() })
            if negotiated.isTranscoding {
                playbackLabel = "兼容播放 · 服务器转码"
            } else {
                playbackLabel = capability == .localDecoder ? "本地解码 · 原画直放" : "系统播放 · 原画直放"
            }
            let streamURL: URL
            if mode == .automatic || connection.certificatePin != nil {
                // This stream is deliberately available only on this Mac's loopback interface.
                player.allowsExternalPlayback = false
                let relay = PinnedPlaybackRelay(sourceURL: negotiated.url, serverURL: connection.baseURL, certificatePin: connection.certificatePin)
                playbackRelay = relay
                streamURL = try await relay.start()
                guard !stopped else { await relay.stop(); return }
            } else {
                streamURL = negotiated.url
            }
            if capability == .localDecoder {
                let engine = try LocalPlaybackEngine()
                localEngine = engine
                engine.onChange = { [weak self] in self?.sample() }
                try await engine.load(url: streamURL, startSeconds: Double(negotiated.resumeTicks) / 10_000_000)
                guard !stopped else { engine.shutdown(); return }
                engine.setVolume(volume)
                await applyInitialPlaybackRate(engine: engine)
                await restorePreferences(engine: engine, mediaSourceID: negotiated.mediaSourceID)
                guard !stopped else { engine.shutdown(); return }
                updateTracks(from: engine.snapshot)
                try await applyInitialSeriesSkip(engine: engine)
                guard !stopped else { engine.shutdown(); return }
                elapsedSeconds = engine.snapshot.seconds
                durationSeconds = engine.snapshot.duration ?? item.durationSeconds
                lastPosition = elapsedSeconds
                startGate.baseline = elapsedSeconds
                outroAdvanceGate.baseline = elapsedSeconds
                preparing = false
                resolveOpeningAspectIfReady()
                localTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sample() }
                }
                resumeAutomatically()
                return
            }
            let playerItem = AVPlayerItem(url: streamURL)
            player.replaceCurrentItem(with: playerItem)
            notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.completeNaturally() }
            })
            notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.failPlayback() }
            })
            notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sample(force: true) }
            })
            // Ready-to-play does not itself constitute playback: check-ins start only when the clock runs.
            let deadline = Date().addingTimeInterval(25)
            while playerItem.status == .unknown && !stopped && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !stopped else { return }
            guard playerItem.status == .readyToPlay else { throw MediaServerError.unsupportedMedia }
            let duration = playerItem.duration.seconds
            var resume = Double(negotiated.resumeTicks) / 10_000_000
            if duration.isFinite, duration > 0 { resume = min(resume, max(0, duration - 0.5)) }
            resume = EpisodeSkipPolicy.initialPosition(resumeSeconds: resume, duration: duration, settings: seriesSkipSettings)
            updateSkipDurationMessage(duration)
            if resume > 0 {
                let success = await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard success else { throw MediaServerError.unsupportedMedia }
            }
            guard !stopped else { return }
            preparing = false
            // A paused or minimized AVPlayer may receive dimensions after readyToPlay
            // without advancing its time observer.
            presentationObservation = playerItem.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.resolveOpeningAspectIfReady() }
            }
            lastPosition = player.currentTime().seconds
            startGate.baseline = lastPosition
            outroAdvanceGate.baseline = lastPosition
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
            stateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sample() }
            }
            resumeAutomatically()
        } catch {
            guard !stopped else { return }
            preparing = false
            errorMessage = connection.compatibilityMode ? "影片未能开始播放。请检查连接、证书和媒体格式。" : "影片未能播放。请检查网络、HTTPS 证书及服务器转码能力，或返回详情尝试兼容播放。"
            if let error = error as? MediaServerError { errorMessage = error.localizedDescription }
            else if let error = error as? LocalPlaybackError { errorMessage = error.localizedDescription }
            await stop()
        }
    }

    func sample(force: Bool = false) {
        guard !stopped, !preparing else { return }
        resolveOpeningAspectIfReady()
        if minimizePausePolicy.blocksExplicitPlayback { pauseForWindow() }
        let seconds: Double
        let paused: Bool
        let playing: Bool
        let seeking: Bool
        if let engine = localEngine {
            let state = engine.snapshot
            if state.failure != nil { failPlayback(); return }
            seconds = state.seconds; paused = state.paused
            seeking = seekingLocally || state.seeking
            playing = state.loaded && !paused && !state.buffering && !seeking
            updateTracks(from: state)
            elapsedSeconds = seconds
            durationSeconds = state.duration ?? item.durationSeconds
            isPaused = paused; isBuffering = state.buffering
            if playbackRate != state.playbackRate { playbackRate = state.playbackRate }
            if state.ended && !seekingLocally {
                Task { [weak self, weak engine] in
                    // A timeline or chapter action may have arrived after this EOF sample.
                    guard let self, let engine, self.localEngine === engine, engine.snapshot.ended,
                          !self.stopped, !self.switchingEpisode, !self.seekingLocally else { return }
                    await self.completeNaturally()
                }
                return
            }
        } else {
            if player.currentItem?.status == .failed { failPlayback(); return }
            seconds = player.currentTime().seconds
            paused = player.rate == 0; seeking = seekingLocally
            playing = player.timeControlStatus == .playing
            elapsedSeconds = seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            durationSeconds = duration.isFinite && duration > 0 ? duration : item.durationSeconds
            isPaused = paused; isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        guard seconds.isFinite, seconds >= 0, !seeking else { return }
        if !didStart {
            guard startGate.observe(seconds: seconds, playing: playing, seeking: seeking) else { return }
            didStart = true
            enqueueReport(ticks: ticks(), start: true, paused: false)
        } else if force || Date().timeIntervalSince(lastReport) >= 10 || paused != lastPaused || abs(seconds - lastPosition) > 3 {
            enqueueReport(ticks: ticks(), start: false, paused: paused)
        }
        lastPaused = paused; lastPosition = seconds
        observeOutro(seconds: seconds, playing: playing, seeking: seeking)
    }

    func configureSeriesSkip(_ access: SeriesPlaybackPreferencesAccess?) {
        seriesSkipAccess = item.type == "Episode" ? access : nil
        seriesSkipSettings = (try? seriesSkipAccess?.load().validated()) ?? .init()
    }

    @discardableResult
    func saveSeriesSkipSettings(_ settings: SeriesSkipSettings) -> Bool {
        guard canConfigureSeriesSkip, let access = seriesSkipAccess else { return false }
        do {
            try access.save(settings.validated())
            seriesSkipSettings = settings
            seriesSkipMessage = nil
            updateSkipDurationMessage(knownSkipDuration)
            return true
        } catch {
            seriesSkipMessage = "跳过设置未能保存，请检查输入、磁盘空间和权限后重试。"
            return false
        }
    }

    private var knownSkipDuration: Double {
        localEngine?.snapshot.duration ?? player.currentItem?.duration.seconds ?? 0
    }

    private func updateSkipDurationMessage(_ duration: Double) {
        guard seriesSkipSettings.introSeconds > 0 || seriesSkipSettings.outroSeconds > 0 else { return }
        if !EpisodeSkipPolicy.isApplicable(duration: duration, settings: seriesSkipSettings) {
            seriesSkipMessage = "本集时长未知或片头片尾时长过长，本集暂不自动跳过。"
        }
    }

    /// Apply once before playback starts. A later manual rewind remains watchable.
    func applyInitialSeriesSkip(engine: LocalPlaybackEngine) async throws {
        let duration = engine.snapshot.duration ?? 0
        updateSkipDurationMessage(duration)
        let current = engine.snapshot.seconds
        let target = EpisodeSkipPolicy.initialPosition(resumeSeconds: current, duration: duration, settings: seriesSkipSettings)
        if target > current + 0.05 { try await engine.seek(to: target) }
    }

    private func observeOutro(seconds: Double, playing: Bool, seeking: Bool) {
        let advancing = outroAdvanceGate.observe(seconds: seconds, playing: playing, seeking: seeking)
        guard didStart, !outroSkipClaimed, !switchingEpisode, !completion.cancelled, advancing,
              let target = EpisodeSkipPolicy.outroTarget(seconds: seconds, duration: knownSkipDuration,
                                                         settings: seriesSkipSettings, playing: playing, seeking: seeking) else { return }
        // Claim synchronously: mpv callbacks and the periodic timer may sample the same frame.
        outroSkipClaimed = true
        seekingOutro = true
        localEngine?.pause()
        outroSkipTask = Task { [weak self] in
            await self?.performOutroSkip(to: target)
        }
    }

    func performOutroSkip(to target: Double) async {
        defer { seekingOutro = false; outroSkipTask = nil }
        guard !stopped, !switchingEpisode, !Task.isCancelled else { return }
        do {
            if let engine = localEngine { try await engine.seek(to: target) }
            else {
                // A newer native scrub cancels the older AV seek with false. It is
                // user intent, not a decoder failure. AV seek preserves rate/pause.
                guard await compatibilitySeek(player, target) else { return }
            }
            guard !stopped, !switchingEpisode, !Task.isCancelled else { return }
            seekingOutro = false
            seriesSkipMessage = "已跳过片尾"
            // Let the decoder reach real EOF. Final progress is its observed position,
            // never a fabricated duration or a forced server watched flag.
            if localEngine != nil { resumeAutomatically() }
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            failPlayback()
        }
    }

    func togglePause() {
        guard !stopped, !preparing, let engine = localEngine else { return }
        if let task = outroSkipTask {
            task.cancel(); engine.pause(); sample(force: true); return
        }
        if engine.snapshot.paused {
            guard minimizePausePolicy.requestExplicitPlayback() else { return }
            engine.play()
        } else { engine.pause() }
        sample(force: true)
    }

    private var seekDuration: Double { localEngine?.snapshot.duration ?? durationSeconds }
    var canSeek: Bool {
        isActive && !preparing && !switchingEpisode && localEngine != nil && seekDuration.isFinite && seekDuration > 0
    }

    func requestSeek(_ direction: PlaybackSeekDirection) {
        requestSeek(to: direction.target(from: manualSeekTarget ?? elapsedSeconds, preferences: interfacePreferences))
    }

    /// Register each UI action synchronously so another key or click can build on
    /// the requested position while the decoder still reports its previous frame.
    func requestSeek(to seconds: Double) {
        guard canSeek, seconds.isFinite, let engine = localEngine else { return }
        let target = min(max(0, seekDuration - 0.5), max(0, seconds))
        manualSeekTask?.cancel()
        manualSeekTarget = target
        if let outro = outroSkipTask, !outro.isCancelled {
            // Outro skipping temporarily paused a playing engine. A new user seek
            // replaces its destination and restores that intent through the window's pause policy.
            outro.cancel()
            resumeAutomatically()
        }
        manualSeekTask = Task {
            guard !Task.isCancelled else { return }
            do {
                try await engine.seek(to: target)
                guard !Task.isCancelled else { return }
                manualSeekTask = nil
                manualSeekTarget = nil
                if !didStart { startGate.baseline = engine.snapshot.seconds }
                outroAdvanceGate.baseline = engine.snapshot.seconds
                sample(force: true)
            } catch {
                // A newer seek, a closing window, or an episode switch owns the result.
                guard !Task.isCancelled else { return }
                manualSeekTask = nil
                manualSeekTarget = nil
                failPlayback()
            }
        }
    }

    func seek(to seconds: Double) async {
        requestSeek(to: seconds)
        await manualSeekTask?.value
    }

    private func cancelManualSeek() {
        manualSeekTask?.cancel()
        manualSeekTask = nil
        manualSeekTarget = nil
    }

    var volumeState: PlaybackVolumeState {
        let actualVolume = localEngine == nil ? Double(player.volume) : volume
        return PlaybackVolumeState(volume: actualVolume, isMuted: player.isMuted || actualVolume == 0,
                                   volumeBeforeMute: actualVolume > 0 ? actualVolume : volumeBeforeMute).normalized
    }

    /// Apply while the next engine is still paused; this must not save a new
    /// preference merely because a window was created or a session continued.
    func applyInitialVolume(_ state: PlaybackVolumeState) {
        guard preparing, !stopped else { return }
        let state = state.normalized
        volumeBeforeMute = state.volumeBeforeMute
        volume = state.isMuted ? 0 : state.volume
        // AVPlayer's system mute button only toggles isMuted. Keep its audible
        // level underneath a saved local-player mute so that system unmute works.
        player.volume = Float(state.isMuted && state.volume == 0 ? state.volumeBeforeMute : state.volume)
        player.isMuted = state.isMuted
        localEngine?.setVolume(volume)
        lastNotifiedVolume = volumeState
    }

    func setVolume(_ value: Double) {
        guard !stopped, value.isFinite else { return }
        volume = min(1, max(0, value))
        if volume > 0 { volumeBeforeMute = volume }
        localEngine?.setVolume(volume)
        player.volume = Float(volume)
        player.isMuted = volume == 0
        notifyVolumeChange()
    }

    func toggleMute() {
        let state = volumeState
        setVolume(state.isMuted || state.volume == 0 ? state.volumeBeforeMute : 0)
    }

    private func compatibilityVolumeChanged() {
        guard !preparing else { return }
        captureCompatibilityVolume()
    }

    private func captureCompatibilityVolume() {
        guard !stopped, localEngine == nil else { return }
        let actualVolume = Double(player.volume)
        if actualVolume > 0 { volumeBeforeMute = actualVolume }
        volume = player.isMuted ? 0 : actualVolume
        notifyVolumeChange()
    }

    private func notifyVolumeChange() {
        guard !stopped else { return }
        let state = volumeState
        guard state != lastNotifiedVolume else { return }
        lastNotifiedVolume = state
        onVolumeChange?(state)
    }

    /// Continue at the same listening level, including the user's pre-mute level.
    func inheritContinuationVolume(from previous: NativePlaybackController) {
        applyInitialVolume(previous.volumeState)
    }

    func inheritContinuationPlaybackRate(from previous: NativePlaybackController) {
        guard preparing, !stopped else { return }
        initialPlaybackRate = previous.playbackRate
        playbackRate = initialPlaybackRate
    }

    func applyInitialPlaybackRate(engine: LocalPlaybackEngine) async {
        guard initialPlaybackRate != 1 else { return }
        do {
            try await engine.setPlaybackRate(initialPlaybackRate)
            guard !stopped else { return }
            playbackRate = engine.snapshot.playbackRate
        } catch {
            guard !stopped else { return }
            playbackRate = engine.snapshot.playbackRate
            playbackControlMessage = "未能沿用播放速度，已使用当前速度，可重新选择。"
        }
    }

    func setPlaybackRate(_ value: Double) async {
        guard isActive, !preparing, !stopping, !changingPlaybackRate, let engine = localEngine else { return }
        changingPlaybackRate = true
        defer { changingPlaybackRate = false }
        do {
            try await engine.setPlaybackRate(value)
            guard !stopped else { return }
            playbackRate = engine.snapshot.playbackRate
            playbackControlMessage = nil
        } catch {
            guard !stopped else { return }
            playbackControlMessage = "未能调整播放速度，请重新选择。"
        }
    }

    func stepPlaybackRate(increasing: Bool) async {
        let next = increasing ? PlaybackRate.presets.first(where: { $0 > playbackRate + 0.001 })
                              : PlaybackRate.presets.last(where: { $0 < playbackRate - 0.001 })
        if let next { await setPlaybackRate(next) }
    }

    private func updateTracks(from state: LocalPlaybackSnapshot) {
        if audioTracks != state.audioTracks { audioTracks = state.audioTracks }
        if subtitleTracks != state.subtitleTracks { subtitleTracks = state.subtitleTracks }
        if selectedAudioTrackID != state.selectedAudioTrackID { selectedAudioTrackID = state.selectedAudioTrackID }
        if selectedSubtitleTrackID != state.selectedSubtitleTrackID { selectedSubtitleTrackID = state.selectedSubtitleTrackID }
    }

    func useApplicationAudioSelection() async {
        await changeTrack { [self] engine in
            try await applyApplicationAudio(engine: engine)
            remember { $0.audio = nil }
        }
    }

    func useApplicationSubtitleSelection() async {
        await changeTrack { [self] engine in
            try await applyApplicationSubtitle(engine: engine)
            remember { $0.subtitle = nil }
        }
    }

    private func applyApplicationAudio(engine: LocalPlaybackEngine) async throws {
        let preferred = playbackDefaults.preferredAudioLanguage.flatMap {
            TrackLanguagePolicy.audioTrackID(in: engine.snapshot.audioTracks, preferred: $0)
        }
        if let id = preferred ?? mediaDefaultAudioTrackID { try await engine.selectAudioTrack(id: id) }
    }

    private func applyApplicationSubtitle(engine: LocalPlaybackEngine) async throws {
        switch playbackDefaults.subtitleMode {
        case .off:
            try await engine.selectSubtitleTrack(id: nil)
        case .mediaDefault:
            try await engine.selectSubtitleTrack(id: mediaDefaultSubtitleTrackID)
        case .preferredLanguage:
            let choice = TrackLanguagePolicy.subtitle(in: engine.snapshot.subtitleTracks,
                serverSubtitles: serverSubtitles, preferred: playbackDefaults.preferredSubtitleLanguage)
            switch choice {
            case .embedded(let id): try await engine.selectSubtitleTrack(id: id)
            case .server(let subtitle):
                do { try await loadServerSubtitle(subtitle, engine: engine) }
                catch {
                    guard !stopped else { throw error }
                    try await engine.selectSubtitleTrack(id: mediaDefaultSubtitleTrackID)
                    trackMessage = "首选字幕暂未加载，已使用媒体默认字幕；可在字幕菜单中重试。"
                }
            case nil: try await engine.selectSubtitleTrack(id: mediaDefaultSubtitleTrackID)
            }
        }
    }

    func selectAudioTrack(_ id: Int) async {
        await changeTrack { [self] engine in
            try await engine.selectAudioTrack(id: id)
            guard let track = engine.snapshot.audioTracks.first(where: { $0.id == id }) else { return }
            remember { $0.audio = SavedTrackSelection(track: track, among: engine.snapshot.audioTracks) }
        }
    }

    func selectSubtitleTrack(_ id: Int?) async {
        await changeTrack { [self] engine in
            try await engine.selectSubtitleTrack(id: id)
            let selection: SavedSubtitleSelection
            if let id {
                if let archive = importedLocalTracks[id] { selection = .local(archive) }
                else if let server = importedServerTracks.first(where: { $0.value == id }),
                        let candidate = serverSubtitles.first(where: { $0.id == server.key }) {
                    selection = .server(SavedServerSubtitleSelection(candidate))
                }
                else if let track = engine.snapshot.subtitleTracks.first(where: { $0.id == id && !$0.isExternal }) {
                    selection = .embedded(SavedTrackSelection(track: track, among: engine.snapshot.subtitleTracks))
                } else { return }
            } else { selection = .off }
            remember { $0.subtitle = selection }
        }
    }

    func serverSubtitleIsSelected(_ subtitle: ServerSubtitle) -> Bool {
        guard let id = importedServerTracks[subtitle.id] else { return false }
        return selectedSubtitleTrackID == id
    }

    func selectServerSubtitle(_ subtitle: ServerSubtitle) async {
        guard serverSubtitles.contains(subtitle) else { return }
        await changeTrack { [self] engine in
            try await loadServerSubtitle(subtitle, engine: engine)
            remember { $0.subtitle = .server(SavedServerSubtitleSelection(subtitle)) }
        }
    }

    private func loadServerSubtitle(_ subtitle: ServerSubtitle, engine: LocalPlaybackEngine) async throws {
        if let id = importedServerTracks[subtitle.id], engine.snapshot.subtitleTracks.contains(where: { $0.id == id }) {
            try await engine.selectSubtitleTrack(id: id)
            return
        }
        let downloaded = try await client.downloadSubtitle(subtitle)
        try Task.checkCancellation()
        guard !stopped, localEngine === engine else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixSubtitleDownload-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("服务器字幕").appendingPathExtension(downloaded.fileExtension)
        guard FileManager.default.createFile(atPath: file.path, contents: downloaded.data, attributes: [.posixPermissions: 0o600]) else {
            throw LocalPlaybackError.invalidSubtitle
        }
        let track = try await engine.addExternalSubtitle(url: file, title: subtitle.title)
        guard !stopped, localEngine === engine else { throw CancellationError() }
        importedServerTracks[subtitle.id] = track.id
    }

    func setSubtitlePresentation(_ value: SubtitlePresentation) async {
        await applySubtitlePresentation(value) { $0.presentation = $1 }
    }

    func setSubtitleDelay(_ seconds: Double) async {
        var value = subtitlePresentation
        value.delaySeconds = seconds
        await applySubtitlePresentation(value) { $0.setSubtitleDelay($1.delaySeconds) }
    }

    func setSubtitleFontSize(_ size: Double) async {
        var value = subtitlePresentation
        value.fontSize = size
        await applySubtitlePresentation(value) { $0.setSubtitleFontSize($1.fontSize) }
    }

    func setSubtitleStyle(_ style: SubtitlePresentation.Style) async {
        var value = subtitlePresentation
        value.style = style
        await applySubtitlePresentation(value) { $0.setSubtitleStyle($1.style) }
    }

    func useApplicationSubtitleDefaults() async {
        var value = playbackDefaults.subtitlePresentation
        value.delaySeconds = subtitlePresentation.delaySeconds
        await applySubtitlePresentation(value) { preferences, applied in
            preferences.useApplicationSubtitleDefaults()
            preferences.setSubtitleDelay(applied.delaySeconds)
        }
    }

    private func applySubtitlePresentation(_ value: SubtitlePresentation,
                                          remember edit: @escaping (inout FilmPlaybackPreferences, SubtitlePresentation) -> Void) async {
        await changeTrack { [self] engine in
            try await engine.applySubtitlePresentation(value)
            guard !stopped else { return }
            subtitlePresentation = engine.snapshot.subtitlePresentation
            remember { edit(&$0, subtitlePresentation) }
        }
    }

    private func remember(_ edit: (inout FilmPlaybackPreferences) -> Void) {
        guard !stopped, var preferences = filmPreferences else { return }
        edit(&preferences)
        preferences.updatedAt = Date()
        filmPreferences = preferences
        guard let access = preferenceAccess else { return }
        do { try access.save(preferences) }
        catch { trackMessage = "当前设置已生效，但未能保存；请检查磁盘空间和权限。" }
    }

    /// Restore before the playback clock starts. A missing track must never
    /// overwrite the remembered choice with a newly assigned decoder ID.
    func restorePreferences(engine: LocalPlaybackEngine, mediaSourceID: String) async {
        guard !stopped else { return }
        localEngine = engine
        if !capturedMediaDefaults {
            mediaDefaultAudioTrackID = engine.snapshot.selectedAudioTrackID
            mediaDefaultSubtitleTrackID = engine.snapshot.selectedSubtitleTrackID
            capturedMediaDefaults = true
        }
        let access = preferenceAccess
        let preferences = access?.load(mediaSourceID)
            ?? FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item.id, mediaSourceID: mediaSourceID))
        filmPreferences = preferences
        var missing = false
        do {
            try await engine.applySubtitlePresentation(preferences.resolvedPresentation(defaults: playbackDefaults.subtitlePresentation))
            guard !stopped else { return }
            subtitlePresentation = engine.snapshot.subtitlePresentation
        } catch { if !stopped { trackMessage = "字幕设置暂未恢复，可在字幕设置中重试。" } }
        guard !stopped else { return }
        if let audio = preferences.audio {
            if let id = audio.resolve(in: engine.snapshot.audioTracks) {
                do { try await engine.selectAudioTrack(id: id) } catch { missing = true }
            } else { missing = true }
        } else {
            do { try await applyApplicationAudio(engine: engine) }
            catch { trackMessage = "首选音轨暂未恢复，可在音轨菜单中重试。" }
        }
        guard !stopped else { return }
        if let subtitle = preferences.subtitle {
            do {
                switch subtitle {
                case .off: try await engine.selectSubtitleTrack(id: nil)
                case .embedded(let saved):
                    guard let id = saved.resolve(in: engine.snapshot.subtitleTracks.filter { !$0.isExternal }) else { throw LocalPlaybackError.invalidTrack }
                    try await engine.selectSubtitleTrack(id: id)
                case .server(let saved):
                    guard let candidate = saved.resolve(in: serverSubtitles) else { throw LocalPlaybackError.invalidTrack }
                    try await loadServerSubtitle(candidate, engine: engine)
                case .local(let archive):
                    guard let access else { throw SubtitleArchiveError.invalidReference }
                    let track = try await engine.addExternalSubtitle(url: access.url(archive), title: archive.displayName)
                    guard !stopped else { return }
                    importedLocalTracks[track.id] = archive
                }
            } catch {
                missing = true
                // Missing remembered captions should not silently display a
                // different default language. Keep the saved preference intact.
                if !stopped { try? await engine.selectSubtitleTrack(id: nil) }
            }
        } else {
            do { try await applyApplicationSubtitle(engine: engine) }
            catch { trackMessage = "默认字幕暂未恢复，可在字幕菜单中重试。" }
        }
        if missing, !stopped { trackMessage = "上次选择的部分音轨或字幕已不可用，请重新选择。" }
    }

    func importExternalSubtitle() async {
        guard !stopped, !preparing, !changingTrack, let window = localEngine?.videoView.window else { return }
        let panel = NSOpenPanel()
        panel.title = "添加外挂字幕"
        panel.message = "支持 SRT、ASS、SSA、VTT；UTF-8 或 UTF-16 编码，最大 10 MB。"
        panel.prompt = "添加字幕"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, !stopped else { return }
        await importSubtitle(url: url)
    }

    // File approval is obtained by NSOpenPanel above. Kept separate for a bounded import test.
    func importSubtitle(url: URL) async {
        await changeTrack { [self] engine in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let access = preferenceAccess else {
                try await engine.addExternalSubtitle(url: url)
                return
            }
            let archive = try await access.archive(url)
            do {
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                let track = try await engine.addExternalSubtitle(url: access.url(archive), title: archive.displayName)
                guard !stopped else { throw CancellationError() }
                importedLocalTracks[track.id] = archive
                remember { $0.subtitle = .local(archive) }
            } catch {
                access.discard(archive)
                throw error
            }
        }
    }

    private func changeTrack(_ action: @escaping (LocalPlaybackEngine) async throws -> Void) async {
        guard !stopped, !preparing, !changingTrack, let engine = localEngine else { return }
        changingTrack = true; trackMessage = nil
        let task = Task { [weak self] in
            do { try await action(engine) }
            catch is CancellationError { }
            catch {
                guard let self, !self.stopped, self.localEngine === engine else { return }
                if let error = error as? LocalPlaybackError { self.trackMessage = error.localizedDescription }
                else if let error = error as? MediaServerError { self.trackMessage = error.localizedDescription }
                else if let error = error as? SubtitleArchiveError { self.trackMessage = error.localizedDescription }
                else { self.trackMessage = "未能切换音轨或字幕，请重试或选择其他文件。" }
            }
        }
        trackOperation = task
        await task.value
        trackOperation = nil; changingTrack = false
        guard !stopped, localEngine === engine else { return }
        updateTracks(from: engine.snapshot)
    }

    private func ticks() -> Int64 {
        let seconds = localEngine?.snapshot.seconds ?? player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 10_000_000 else { return journal.ticks }
        return Int64(seconds * 10_000_000)
    }

    private func enqueueReport(ticks: Int64, start: Bool, paused: Bool) {
        lastReport = Date()
        let revision = journal.record(ticks)
        let persisted = persistSnapshot(ticks: journal.ticks, confirmed: false)
        guard !uncertain else { markUncertain(); return }
        guard let reportPump else { return }
        if persisted { syncMessage = "正在同步进度" }
        if start { reportPump.start(ticks: ticks, revision: revision) }
        else { reportPump.progress(ticks: ticks, paused: paused, revision: revision) }
    }

    @discardableResult
    func persistSnapshot(ticks: Int64, confirmed: Bool) -> Bool {
        let succeeded = save(ticks, confirmed)
        localSaveFailed = !succeeded
        pendingProgressSnapshot = succeeded ? nil : ticks
        if !succeeded { syncMessage = "本机进度保存失败 · 请检查磁盘空间与权限" }
        return succeeded
    }

    func markUncertain() {
        uncertain = true
        syncMessage = localSaveFailed ? "服务器进度同步未确认 · 本机进度保存失败" : "进度仅保存在本机 · 下次播放可选择恢复位置"
    }
    private func failPlayback() {
        guard !stopped else { return }
        errorMessage = "播放中断。请检查网络或返回详情重新播放。进度保存状态可在「播放信息」中查看。"
        Task { await stopAfterPlaybackEvent() }
    }

    func cancelAutomaticContinuation() { completion.cancel() }

    func selectEpisode(id: String, fromBeginning: Bool = false) {
        guard canSelectEpisode, episodeSequence?.orderedEpisodes.contains(where: { $0.id == id }) == true,
              fromBeginning || id != item.id || !isActive else { return }
        onSelectEpisode?(id, fromBeginning)
    }
    func beginEpisodeSwitch() -> UUID {
        cancelManualSeek()
        completion.cancel()
        let id = UUID(); episodeSwitchID = id; switchingEpisode = true
        episodeRecoveryChoice = nil; nextEpisodeMessage = nil
        return id
    }
    func isEpisodeSwitchCurrent(_ id: UUID) -> Bool { episodeSwitchID == id }
    func cancelEpisodeSwitch() {
        episodeSwitchID = nil; switchingEpisode = false; episodeRecoveryChoice = nil
        onChooseEpisodeRecovery = nil; onCancelEpisodeRecovery = nil
    }
    func chooseEpisodeRecovery(local: Bool) { onChooseEpisodeRecovery?(local) }
    func cancelEpisodeRecovery() { onCancelEpisodeRecovery?() }
    var episodeProgressAtRisk: Bool { localSaveFailed && uncertain }
    /// Retry only the frozen local snapshot. An uncertain server write must never be replayed.
    func recoverProgressForEpisodeSwitch() -> Bool {
        guard stopped, !stopping else { return false }
        if episodeProgressAtRisk, let ticks = pendingProgressSnapshot {
            persistSnapshot(ticks: ticks, confirmed: false)
            markUncertain()
        }
        return !episodeProgressAtRisk
    }
    var episodeProgressWarning: String? {
        if didStart && uncertain { return "上一集进度仅保存在本机，服务器同步未确认。" }
        if didStart && localSaveFailed { return "上一集已同步到服务器，但本机进度保存失败。" }
        return nil
    }

    func completeNaturally() async {
        guard completion.beginNaturalEnd(started: didStart, stopped: stopped, failed: errorMessage != nil) else {
            // Even a file too short to open a viewing session needs its resources released.
            if !stopped { await stopAfterPlaybackEvent() }
            return
        }
        await stop(naturalEnd: true)
        guard canAutomaticallyContinue else { return }
        await onNaturalCompletion?(self)
    }

    private func stopAfterPlaybackEvent() async {
        // A queued EOF/failure callback is stale once an explicit selection owns teardown.
        guard !switchingEpisode else { return }
        await stop()
    }

    func stop(naturalEnd: Bool = false, forEpisodeSwitch switchID: UUID? = nil) async {
        if !naturalEnd { completion.cancel() }
        if !naturalEnd && (switchID == nil || switchID != episodeSwitchID) { cancelEpisodeSwitch() }
        if let stopTask { await stopTask.value; return }
        // KVO delivers onto MainActor in a task. A system volume change and close
        // can occur in the same turn, so capture the actual controls synchronously
        // before callbacks are detached. The initial baseline suppresses defaults.
        captureCompatibilityVolume()
        stopped = true; stopping = true; preparing = false
        cancelManualSeek()
        onVolumeChange = nil
        volumeObservations.removeAll()
        playbackRateObservation = nil
        outroSkipTask?.cancel()
        trackOperation?.cancel()
        player.pause()
        localEngine?.pause()
        localTimer?.invalidate(); localTimer = nil
        localEngine?.onChange = nil
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        stateObservation = nil
        presentationObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        let finalTicks = ticks()
        let revision = didStart ? journal.record(finalTicks) : journal.revision
        if didStart { persistSnapshot(ticks: finalTicks, confirmed: false) }
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let relay = self.playbackRelay { await relay.stop(); self.playbackRelay = nil }
            if self.didStart, let pump = self.reportPump, !self.uncertain {
                await pump.stop(ticks: finalTicks, revision: revision)
            } else if self.uncertain {
                self.markUncertain()
            }
            if let plan = self.plan { try? await self.client.stopTranscoding(plan: plan) }
            self.player.replaceCurrentItem(with: nil)
            self.localEngine?.shutdown()
            self.stopping = false
        }
        await stopTask?.value
    }
}

private struct NativeVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player; view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct LocalVideoView: NSViewRepresentable {
    let engine: LocalPlaybackEngine
    let interaction: PlaybackInteractionController
    func makeCoordinator() -> PlaybackSurfaceClicks {
        PlaybackSurfaceClicks(onSingle: { interaction.clickedVideo(doubleClick: false) },
                              onDouble: { interaction.clickedVideo(doubleClick: true) })
    }
    func makeNSView(context: Context) -> NSView {
        let view = engine.videoView
        context.coordinator.attach(to: view)
        return view
    }
    static func dismantleNSView(_ view: NSView, coordinator: PlaybackSurfaceClicks) {
        coordinator.detach(from: view)
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct PlaybackContent: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController
    var body: some View {
        ZStack {
            ZStack(alignment: .top) {
                Color.black
                if let engine = controller.localEngine {
                    LocalVideoView(engine: engine, interaction: interaction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeVideoView(player: controller.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if interaction.controlsVisible {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.76), location: 0),
                        .init(color: .black.opacity(0.54), location: 0.46),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: interaction.isFullScreen ? 72 : 56)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .ignoresSafeArea(.container, edges: .top)

            GeometryReader { available in
                ZStack {
                    if controller.preparing { ProgressView("正在准备播放…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                    if let message = controller.errorMessage {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            Text(message).multilineTextAlignment(.center).frame(maxWidth: 440)
                            Text("关闭播放窗口后可返回影片详情。").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(min(32, available.size.width / 12))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if controller.stopping { ProgressView("正在保存进度…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                }
                .frame(width: available.size.width, height: available.size.height)
                .overlay(alignment: .top) { overlays(width: available.size.width) }
            }
        }.preferredColorScheme(.dark)
    }
    private func overlays(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if interaction.isFullScreen {
                HStack(spacing: 8) {
                    if width >= PlaybackWindowGeometry.minimumTitlebarInfoWidth {
                        Color.clear.frame(width: 32, height: 24).accessibilityHidden(true)
                    }
                    Text(controller.item.name)
                        .font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isHeader)
                        .background(SeatSixSidebarGeometry(id: "player-fullscreen-title"))
                        .allowsHitTesting(false)
                    PlaybackInfoButton(controller: controller, interaction: interaction)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(PlaybackOverlayVisibility(visible: interaction.controlsVisible))
            } else if width < PlaybackWindowGeometry.minimumTitlebarInfoWidth {
                PlaybackInfoButton(controller: controller, interaction: interaction)
                    .background(SeatSixSidebarGeometry(id: "player-compact-info"))
                    .padding(.trailing, 4).padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .modifier(PlaybackOverlayVisibility(visible: interaction.controlsVisible))
            }
            if let warning = controller.progressWarning {
                Group {
                    if width < 220 {
                        Text(controller.compactProgressWarning).font(.caption.weight(.semibold))
                    } else {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.medium))
                    }
                }
                    .foregroundStyle(.white)
                    .padding(.horizontal, width < 220 ? 4 : 10).padding(.vertical, 6)
                    .background(SeatSixChrome.raised, in: RoundedRectangle(cornerRadius: 8))
                    .help(warning)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("播放进度提醒").accessibilityValue(warning)
                    .accessibilityAddTraits(.isStaticText)
                    .background(SeatSixSidebarGeometry(id: "player-sync-warning"))
                    .padding(.horizontal, width < 220 ? 4 : 12).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if controller.item.type == "Episode" {
                PlaybackEpisodeHeader(controller: controller, interaction: interaction)
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(PlaybackOverlayVisibility(visible: interaction.controlsVisible))
            }
            if !interaction.controlsAtTop { Spacer(minLength: 0) }
            if controller.localEngine != nil {
                LocalPlaybackControls(controller: controller, interaction: interaction)
                    .padding(.top, interaction.controlsAtTop ? 6 : 0)
                    .onHover { interaction.setControlsHovered($0) }
                    .modifier(PlaybackOverlayVisibility(visible: interaction.controlsVisible))
            }
            if interaction.controlsAtTop { Spacer(minLength: 0) }
        }
    }
}

struct PlaybackEpisodeHeader: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                episodeOptions.padding(10)
                Button { showOptions.toggle() } label: {
                    Image(systemName: "rectangle.stack")
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("分集控制").help("分集控制")
                .popover(isPresented: $showOptions, arrowEdge: .top) {
                    episodeOptions.padding(14).frame(width: 420).preferredColorScheme(.dark)
                }
                .onChange(of: controller.episodeRecoveryChoice != nil, initial: true) { _, needsChoice in
                    if needsChoice { showOptions = true }
                }
            }
            if let message = controller.nextEpisodeMessage {
                feedback(message, marker: "player-episode-message")
            }
            if let message = controller.seriesSkipMessage {
                feedback(message, marker: "player-skip-message")
            }
        }
        .playbackControlGlass(cornerRadius: 12)
        .onChange(of: showOptions) { _, isOpen in interaction.setPopoverOpen(isOpen, owner: "episode-header") }
        .onChange(of: controller.episodeRecoveryChoice != nil, initial: true) { _, needsChoice in
            interaction.setPopoverOpen(needsChoice, owner: "episode-header-recovery")
        }
        .onHover { interaction.setControlsHovered($0, owner: "episode-header") }
        .onDisappear {
            interaction.setControlsHovered(false, owner: "episode-header")
            interaction.setPopoverOpen(false, owner: "episode-header")
            interaction.setPopoverOpen(false, owner: "episode-header-recovery")
        }
    }

    private var episodeOptions: some View {
        PlaybackEpisodeNavigation(controller: controller, interaction: interaction,
                                  showsTransport: controller.localEngine == nil)
    }

    private func feedback(_ message: String, marker: String) -> some View {
        Text(message).font(.caption).lineLimit(3).help(message)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.bottom, 6)
            .background(SeatSixSidebarGeometry(id: marker))
    }
}

private struct PlaybackOverlayVisibility: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
    }
}

@MainActor
final class PlaybackWindowController: NSWindowController, NSWindowDelegate {
    private var controller: NativePlaybackController
    private let onClosing: (NativePlaybackController) -> Void
    private let onClose: (NativePlaybackController) -> Void
    private let geometry = PlaybackWindowGeometryController()
    private let interaction = PlaybackInteractionController()
    private let behavior: PlaybackWindowBehavior
    private let titlebarInfo = NSTitlebarAccessoryViewController()
    private var titlebarVisibility: AnyCancellable?
    private var approvedClose = false
    private var closing = false
    private var appliedInitialWindowMode = false
    var canReplaceController: Bool { !closing && !approvedClose && window != nil }
    init(controller: NativePlaybackController, openingScreen: NSRect? = nil,
         onClosing: @escaping (NativePlaybackController) -> Void,
         onClose: @escaping (NativePlaybackController) -> Void) {
        self.controller = controller; self.onClosing = onClosing; self.onClose = onClose
        self.behavior = PlaybackWindowBehavior(keepOnTop: controller.playbackDefaults.keepPlaybackWindowOnTop)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = controller.item.name
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        titlebarInfo.layoutAttribute = .trailing
        installContent(in: window)
        titlebarVisibility = interaction.$controlsVisible.combineLatest(interaction.$isFullScreen)
            .map { $0 && !$1 }.removeDuplicates()
            .sink { [weak self] visible in
                self?.window?.titleVisibility = visible ? .visible : .hidden
                self?.titlebarInfo.view.isHidden = !visible
            }
        window.isReleasedWhenClosed = false; window.delegate = self
        geometry.attach(to: window, openingScreen: openingScreen, aspectRatio: openingHint(on: openingScreen))
        observeOpeningAspect()
        interaction.attach(to: window, controller: controller)
        behavior.onMiniaturizedChange = { [weak self] value in self?.controller.setWindowMiniaturized(value) }
        behavior.onPinChange = { [weak self] value in self?.controller.setWindowOnTop(value) }
        bindWindowActions()
        behavior.attach(to: window)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func installContent(in window: NSWindow) {
        let host = NSHostingView(rootView: PlaybackContent(controller: controller, interaction: interaction))
        // The controls adapt to the available width. Their ideal size must not
        // enlarge a portrait video window after its frame has been calculated.
        host.sizingOptions = []
        window.contentView = host

        // Replacing an episode also dismisses the old information popover.
        if let index = window.titlebarAccessoryViewControllers.firstIndex(of: titlebarInfo) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        let info = NSHostingView(rootView: PlaybackInfoButton(controller: controller, interaction: interaction))
        info.sizingOptions = []
        info.frame.size = NSSize(width: 44, height: 24)
        info.isHidden = !interaction.controlsVisible || interaction.isFullScreen
        titlebarInfo.view = info
        updateTitlebarInfoPlacement(in: window)
    }
    private func updateTitlebarInfoPlacement(in window: NSWindow) {
        let index = window.titlebarAccessoryViewControllers.firstIndex(of: titlebarInfo)
        if window.frame.width >= PlaybackWindowGeometry.minimumTitlebarInfoWidth {
            if index == nil { window.addTitlebarAccessoryViewController(titlebarInfo) }
        } else if let index {
            // Remove the accessory's AppKit container too, so it cannot intercept traffic-light clicks.
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }
    func windowDidResize(_ notification: Notification) {
        if let window { updateTitlebarInfoPlacement(in: window) }
    }
    func replaceController(_ next: NativePlaybackController) {
        guard canReplaceController, let window else { return }
        interaction.detach()
        controller.onToggleWindowOnTop = nil
        controller.onFitWindowToVideo = nil
        controller.onOpeningAspectRatio = nil
        geometry.cancelOpeningFit()
        next.inheritWindowPause(from: controller)
        // Release the previous SwiftUI controls before binding the new episode's input.
        window.contentView = nil
        controller = next; window.title = next.item.name
        next.setWindowMiniaturized(window.isMiniaturized)
        bindWindowActions()
        interaction.attach(to: window, controller: next)
        installContent(in: window)
    }
    private func bindWindowActions() {
        controller.setWindowOnTop(behavior.keepOnTop)
        controller.onToggleWindowOnTop = { [weak self] in self?.behavior.togglePin() }
        controller.onFitWindowToVideo = { [weak self] ratio in self?.geometry.fitToVideo(aspectRatio: ratio) }
    }
    private func observeOpeningAspect() {
        controller.onOpeningAspectRatio = { [weak self] ratio in self?.geometry.resolveOpeningAspectRatio(ratio) }
    }
    private func openingHint(on screen: NSRect?) -> CGFloat? {
        guard let window,
              let screen = PlaybackWindowGeometry.screen(for: screen ?? window.screen?.visibleFrame,
                                                          screens: NSScreen.screens.map(\.visibleFrame)) else { return nil }
        let titleHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: window.styleMask.subtracting(.fullScreen)).height
        return controller.item.playbackAspectRatio(for: controller.requestedMediaSourceID) { ratio in
            // A malformed but finite server ratio can round the window to just its title bar.
            guard let frame = PlaybackWindowGeometry.openingFrame(aspectRatio: ratio, titleBarHeight: titleHeight,
                                                                  screen: screen) else { return false }
            return frame.width >= 1 && frame.height - titleHeight >= 1
        }
    }
    override func showWindow(_ sender: Any?) {
        if let window, window.isMiniaturized { window.deminiaturize(sender) }
        super.showWindow(sender)
        geometry.activate()
        if !appliedInitialWindowMode {
            appliedInitialWindowMode = true
            if controller.playbackDefaults.playbackWindowMode == .fullScreen,
               let window, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
    func resetGeometry() {
        let decoded = controller.preparing ? nil : controller.displayedAspectRatio
        let hint = openingHint(on: window?.frame)
        geometry.reset(aspectRatio: decoded ?? hint, awaitingDecodedAspect: decoded == nil)
        if decoded == nil { observeOpeningAspect() }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { geometry.fullScreenTransitionFailed(); interaction.fullScreenTransitionFailed(); behavior.fullScreenTransitionFailed() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { geometry.fullScreenTransitionFailed(); interaction.fullScreenTransitionFailed(); behavior.fullScreenTransitionFailed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard !closing else { return false }
        closing = true
        controller.onOpeningAspectRatio = nil
        geometry.cancelOpeningFit()
        controller.cancelAutomaticContinuation(); onClosing(controller)
        Task { await controller.stop(); approvedClose = true; sender.close() }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        controller.cancelAutomaticContinuation(); controller.onToggleWindowOnTop = nil
        controller.onFitWindowToVideo = nil
        controller.onOpeningAspectRatio = nil
        geometry.cancelOpeningFit()
        behavior.detach(); interaction.detach(); onClose(controller)
    }
}
