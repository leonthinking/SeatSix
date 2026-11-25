import AppKit
import CMPV
import CryptoKit
import Darwin
import OpenGL.GL3

public struct LocalPlaybackTrack: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case audio, subtitle }
    public let id: Int
    public let kind: Kind
    public let title: String?
    public let language: String?
    public let codec: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let isExternal: Bool
    public let channelCount: Int?

    public init(id: Int, kind: Kind, title: String? = nil, language: String? = nil,
                codec: String? = nil, isDefault: Bool = false, isForced: Bool = false,
                isExternal: Bool = false, channelCount: Int? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.language = language
        self.codec = codec; self.isDefault = isDefault; self.isForced = isForced
        self.isExternal = isExternal; self.channelCount = channelCount
    }
}

public struct LocalPlaybackSnapshot: Equatable, Sendable {
    public var seconds: Double = 0
    public var duration: Double?
    public var paused = true
    public var playbackRate: Double = 1
    public var audioPitchCorrectionEnabled = true
    public var buffering = false
    public var seeking = false
    public var loaded = false
    public var ended = false
    public var failure: String?
    public var videoWidth = 0
    public var videoHeight = 0
    /// Display aspect after pixel-aspect correction, filters and video-output rotation.
    public var displayAspectRatio: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var inputBytesPerSecond: Double = 0
    public var audioPTS: Double?
    public var audioOutput: String?
    public var hardwareDecoder: String?
    public var chapters: [LocalPlaybackChapter] = []
    public var audioTracks: [LocalPlaybackTrack] = []
    public var subtitleTracks: [LocalPlaybackTrack] = []
    public var selectedAudioTrackID: Int?
    public var selectedSubtitleTrackID: Int?
    /// Text evidence is unavailable for image-based PGS/VobSub subtitles.
    public var subtitleText: String?
    /// Published only after every style/timing command has been acknowledged.
    public var subtitlePresentation = SubtitlePresentation()
}

public struct LocalPlaybackChapter: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String?
    public let start: Double
}

public struct DecodedFrameEvidence: Sendable {
    public let width: Int
    public let height: Int
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let sampleSHA256: String
    public let nonBlackPixelCount: Int
}

public enum LocalPlaybackError: Error, LocalizedError, Equatable {
    case invalidURL, invalidTime, unavailable, closed, superseded, timeout, decodingFailed(Int32), noVideoFrame
    case invalidTrack, subtitleTrackConflict, trackOperationInProgress, invalidSubtitle, subtitleTooLarge, invalidPlaybackRate, playbackRateOperationInProgress
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "本地解码器仅接受应用的本机中继或本地文件地址。"
        case .invalidTime: return "播放位置必须是有效的非负时间。"
        case .unavailable: return "本地播放引擎无法初始化。"
        case .closed: return "播放器已关闭。"
        case .superseded: return "播放操作已被新的操作替代。"
        case .timeout: return "媒体加载或跳转超时，请检查连接后重试。"
        case .decodingFailed(let code): return "本地解码失败（\(code)）。"
        case .noVideoFrame: return "尚未解码出视频画面。"
        case .subtitleTrackConflict: return "此轨正在用作次字幕，请先更改次字幕。"
        case .invalidTrack: return "所选音轨或字幕已不可用，请重新选择。"
        case .trackOperationInProgress: return "正在切换音轨或字幕，请稍后重试。"
        case .invalidSubtitle: return "请选择有效的本地 SRT、ASS、SSA 或 VTT 文本字幕文件。"
        case .subtitleTooLarge: return "字幕文件不能超过 10 MB，单次播放最多添加 32 个外挂字幕。"
        case .invalidPlaybackRate: return "播放速度必须介于 0.5 倍和 2 倍之间。"
        case .playbackRateOperationInProgress: return "正在调整播放速度，请稍后重试。"
        }
    }
}

// mpv invokes render notifications on internal threads. The callback only
// coalesces an asynchronous main-queue delivery: it never renders, calls mpv,
// or synchronously waits for the main actor.
private final class RenderNotification: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var queued = false
    private let deliver: @MainActor () -> Void
    init(deliver: @escaping @MainActor () -> Void) { self.deliver = deliver }
    func signal() {
        lock.lock()
        guard active, !queued else { lock.unlock(); return }
        queued = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.dispatch() }
    }
    @MainActor private func dispatch() {
        lock.lock()
        queued = false
        let shouldDeliver = active
        lock.unlock()
        if shouldDeliver { deliver() }
    }
    func cancel() { lock.lock(); active = false; lock.unlock() }
}

// Owns the C objects independently of the engine/view so teardown always releases the
// renderer with its GL context current, before mpv itself is terminated.
private final class MPVResources {
    var handle: OpaquePointer?
    var renderNotification: RenderNotification?
    var subtitleDirectory: URL?
    let context: NSOpenGLContext
    init(handle: OpaquePointer, context: NSOpenGLContext) { self.handle = handle; self.context = context }
    func close() {
        guard let handle else { return }
        renderNotification?.cancel()
        context.makeCurrentContext()
        seatsix_mpv_render_destroy(handle)
        seatsix_mpv_destroy(handle)
        self.handle = nil
        if let subtitleDirectory { try? FileManager.default.removeItem(at: subtitleDirectory) }
        subtitleDirectory = nil
        NSOpenGLContext.clearCurrentContext()
    }
    deinit { close() }
}

@MainActor
public final class LocalPlaybackEngine {
    public nonisolated static var isAvailable: Bool { seatsix_mpv_available() != 0 }
    public private(set) var snapshot = LocalPlaybackSnapshot()
    public var onChange: (() -> Void)?
    public var videoView: NSView { surface }
    /// Successful renders after an mpv FRAME notification. Explicit screenshots
    /// and view redraws without a new frame do not increase this count.
    public var renderedFrameCount: UInt64 {
        resources.handle.map { seatsix_mpv_rendered_frame_count($0) } ?? 0
    }
    // Internal observability for lifecycle regression tests; never waits on mpv.
    var pendingTrackCommandCount: Int {
        resources.handle.map { Int(seatsix_mpv_pending_track_commands($0)) } ?? 0
    }
    private let resources: MPVResources
    private let surface: MPVVideoView
    private var pollTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var restarts: UInt64 = 0
    private var stopReplies: UInt64 = 0
    private var trackOperationInProgress = false
    private var playbackRateOperationInProgress = false
    private var loading = false
    private var externalSubtitleCount = 0
    private let subtitleReader: @Sendable (URL) throws -> Data

    public convenience init() throws {
        try self.init(subtitleReader: { url in try Self.validatedSubtitleData(url: url) })
    }

    init(subtitleReader: @escaping @Sendable (URL) throws -> Data) throws {
        self.subtitleReader = subtitleReader
        var error: Int32 = 0
        guard let handle = seatsix_mpv_create(&error) else { throw LocalPlaybackError.unavailable }
        let attributes: [NSOpenGLPixelFormatAttribute] = [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core), UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8, 0]
        guard let format = NSOpenGLPixelFormat(attributes: attributes), let context = NSOpenGLContext(format: format, share: nil) else {
            seatsix_mpv_destroy(handle); throw LocalPlaybackError.unavailable
        }
        resources = MPVResources(handle: handle, context: context)
        surface = MPVVideoView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), pixelFormat: format)!
        surface.wantsBestResolutionOpenGLSurface = true
        surface.openGLContext = context
        surface.resources = resources
        // Disable all user-controlled code/config and all automatic external loading.
        let options = [
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"),
            ("autoload-files", "no"), ("sub-auto", "no"), ("audio-file-auto", "no"),
            ("access-references", "no"), ("load-unsafe-playlists", "no"),
            ("terminal", "no"), ("msg-level", "all=no"), ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"), ("osc", "no"), ("osd-level", "0"),
            ("vo", "libmpv"), ("hwdec", "videotoolbox-copy"), ("hwdec-software-fallback", "yes"),
            ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"),
            ("speed", "1"), ("audio-pitch-correction", "yes"),
            ("hr-seek", "yes"), ("network-timeout", "20"), ("cache", "yes"),
            ("demuxer-max-bytes", "64MiB"), ("demuxer-max-back-bytes", "16MiB"),
            ("demuxer-lavf-o", "protocol_whitelist=[file,http,tcp,crypto]")
        ]
        for (name, value) in options + SubtitlePresentation().mpvOptions {
            guard seatsix_mpv_option(handle, name, value) >= 0 else { resources.close(); throw LocalPlaybackError.unavailable }
        }
        guard seatsix_mpv_initialize(handle) >= 0 else { resources.close(); throw LocalPlaybackError.unavailable }
        context.makeCurrentContext()
        guard seatsix_mpv_render_create(handle) >= 0 else { resources.close(); throw LocalPlaybackError.unavailable }
        NSOpenGLContext.clearCurrentContext()
        let notification = RenderNotification { [weak self] in self?.renderUpdate() }
        resources.renderNotification = notification
        seatsix_mpv_render_set_callback(handle, { context in
            guard let context else { return }
            Unmanaged<RenderNotification>.fromOpaque(context).takeUnretainedValue().signal()
        }, Unmanaged.passRetained(notification).toOpaque(), { context in
            guard let context else { return }
            Unmanaged<RenderNotification>.fromOpaque(context).release()
        })
        // A Swift task also runs in command-line probes and async XCTest, where
        // no AppKit run loop is pumping Foundation timers.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
    }

    deinit { pollTask?.cancel(); resources.close() }

    public static func validate(url: URL) throws {
        guard ["http", "file"].contains(url.scheme?.lowercased() ?? ""), [url.user, url.password].allSatisfy({ $0 == nil }),
              url.fragment == nil else { throw LocalPlaybackError.invalidURL }
        if url.isFileURL {
            guard (url.host == nil || url.host == "" || url.host == "localhost"), url.path.hasPrefix("/"), url.query == nil else { throw LocalPlaybackError.invalidURL }
        } else {
            guard url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port) else { throw LocalPlaybackError.invalidURL }
        }
    }

    public static func boundedTime(_ seconds: Double, duration: Double?) throws -> Double {
        guard seconds.isFinite, seconds >= 0 else { throw LocalPlaybackError.invalidTime }
        guard let duration, duration.isFinite, duration > 0 else { return seconds }
        return min(seconds, max(0, duration - 0.05))
    }

    public func load(url: URL, startSeconds: Double = 0) async throws {
        try Self.validate(url: url)
        _ = try Self.boundedTime(startSeconds, duration: nil)
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        generation &+= 1
        seekGeneration &+= 1
        let operation = generation
        loading = true
        defer { if operation == generation { loading = false } }
        snapshot.failure = nil
        // sub-add is genuinely asynchronous and bound to this mpv handle. End
        // all old-file commands before a new file can receive tracks from them.
        seatsix_mpv_abort_track_commands(handle)
        try await wait(operation: operation) { seatsix_mpv_pending_track_commands(handle) == 0 }
        // A replacement can interrupt a formatting batch after some properties
        // changed. Reassert the last fully acknowledged set before loading the
        // new media so partially applied options cannot leak into it.
        if snapshot.loaded {
            let clear = seatsix_mpv_track_command(handle, "set", "secondary-sid", "no", nil)
            try await wait(operation: operation) { try self.trackCommandCompleted(clear) }
        }
        adjustments.removeValue(forKey: .secondarySubtitle)
        try await setSubtitlePresentation(snapshot.subtitlePresentation, operation: operation)
        let stoppedBefore = stopReplies
        try check(seatsix_mpv_command(handle, "stop", nil, nil, nil))
        // Wait for the old file to become idle before accepting FILE_LOADED events
        // for the next load. This also makes reusing an engine deterministic.
        try await wait(operation: operation) { self.stopReplies > stoppedBefore && self.flag("idle-active") }
        let presentation = snapshot.subtitlePresentation
        let playbackRate = snapshot.playbackRate
        snapshot = LocalPlaybackSnapshot()
        // mpv options belong to the engine and survive replacing its media.
        snapshot.subtitlePresentation = presentation
        snapshot.playbackRate = playbackRate
        snapshot.buffering = true
        snapshot.seeking = true
        _ = seatsix_mpv_set_flag(handle, "pause", 1)
        let location = url.isFileURL ? url.path : url.absoluteString
        try check(seatsix_mpv_command(handle, "loadfile", location, "replace", nil))
        try await wait(operation: operation) { self.snapshot.loaded }
        try await seek(to: startSeconds)
        try ensureCurrent(operation)
        pause()
        snapshot.seeking = false
        onChange?()
    }

    public func play() { guard let handle = resources.handle, snapshot.loaded, snapshot.failure == nil else { return }; _ = seatsix_mpv_set_flag(handle, "pause", 0); tick() }
    public func pause() { guard let handle = resources.handle else { return }; _ = seatsix_mpv_set_flag(handle, "pause", 1); tick() }
    public func setVolume(_ volume: Double, muted: Bool = false) {
        guard let handle = resources.handle, volume.isFinite else { return }
        let gain = min(1, max(0, volume))
        seatsix_mpv_set_audio_level(handle, gain * 100, muted || gain == 0 ? 1 : 0)
    }

    // Observations from mpv, distinct from the requested controls.
    var observedSoftwareVolume: Double { number("volume") / 100 }

    var rendererMuted: Bool? {
        guard let handle = resources.handle else { return nil }
        var value: Int32 = 0
        guard seatsix_mpv_flag(handle, "ao-mute", &value) >= 0 else { return nil }
        return value != 0
    }

    /// Waits for the asynchronous mpv acknowledgement and its actual observed
    /// property without blocking rendering or toggling pause. Rate belongs to
    /// this engine, survives seek/reload, and starts at 1 for a new engine.
    public func setPlaybackRate(_ rate: Double) async throws {
        try Task.checkCancellation()
        try PlaybackRate.validate(rate)
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        guard !loading, !playbackRateOperationInProgress else { throw LocalPlaybackError.playbackRateOperationInProgress }
        playbackRateOperationInProgress = true
        defer { playbackRateOperationInProgress = false }
        let operation = generation
        let command = seatsix_mpv_track_command(handle, "set", "speed", String(rate), nil)
        defer { if resources.handle == handle { seatsix_mpv_abort_track_command(handle, command) } }
        let completion = Task { @MainActor in
            try await self.wait(operation: operation) {
                try self.trackCommandCompleted(command) && abs(self.snapshot.playbackRate - rate) < 0.0001
            }
            self.onChange?()
        }
        try await completion.value
        try Task.checkCancellation()
    }

    public func seek(to seconds: Double) async throws {
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        let target = try Self.boundedTime(seconds, duration: snapshot.duration)
        guard snapshot.loaded else { throw LocalPlaybackError.noVideoFrame }
        seekGeneration &+= 1
        let seekOperation = seekGeneration
        let operation = generation
        let restart = restarts
        defer { if seekGeneration == seekOperation { snapshot.seeking = false } }
        snapshot.seeking = true
        snapshot.ended = false
        try check(seatsix_mpv_command(handle, "seek", String(target), "absolute+exact", nil))
        try await wait(operation: operation) {
            guard self.seekGeneration == seekOperation else { throw LocalPlaybackError.superseded }
            let actual = self.number("time-pos", fallback: -.infinity)
            return self.restarts > restart && !self.flag("seeking") && actual.isFinite && abs(actual - target) <= 0.15
        }
        guard seekGeneration == seekOperation else { throw LocalPlaybackError.superseded }
        snapshot.seeking = false
        // A seek away from EOF may drain the old end event before mpv restarts.
        // At acknowledgement the observed EOF flag belongs to the new position.
        tick(afterSeek: true)
    }

    private func readChapters() -> [LocalPlaybackChapter] {
        guard let handle = resources.handle else { return [] }
        return (0..<seatsix_mpv_chapter_count(handle)).compactMap { index in
            var entry = seatsix_mpv_chapter()
            guard seatsix_mpv_chapter_at(handle, index, &entry) != 0,
                  entry.start.isFinite, entry.start >= 0 else { return nil }
            return LocalPlaybackChapter(id: Int(index), title: entry.title.map(String.init(cString:)), start: entry.start)
        }
    }

    public private(set) var adjustments: [MediaAdjustment: Double] = [:]

    public func adjust(_ setting: MediaAdjustment, to value: Double) async throws {
        try Task.checkCancellation()
        guard let handle = resources.handle, snapshot.loaded else { throw LocalPlaybackError.noVideoFrame }
        guard !loading, !trackOperationInProgress, seatsix_mpv_pending_track_commands(handle) == 0
        else { throw LocalPlaybackError.trackOperationInProgress }
        let (property, argument) = try setting.option(value, previous: adjustments)
        if setting == .secondarySubtitle, value != 0,
           !snapshot.subtitleTracks.contains(where: { $0.id == Int(value) && $0.id != snapshot.selectedSubtitleTrackID }) {
            throw LocalPlaybackError.invalidTrack
        }
        trackOperationInProgress = true
        defer { trackOperationInProgress = false }
        let operation = generation
        let command = seatsix_mpv_track_command(handle, "set", property, argument, nil)
        // Finish tracking an already submitted engine command even if the panel closes.
        let acknowledgement = Task { @MainActor in
            try await self.wait(operation: operation) { try self.trackCommandCompleted(command) }
            self.adjustments[setting] = value
            self.onChange?()
        }
        try await acknowledgement.value
    }

    public func selectAudioTrack(id: Int) async throws {
        try await selectTrack(id: id, kind: .audio)
    }

    public func selectSubtitleTrack(id: Int?) async throws {
        if let id, adjustments[.secondarySubtitle] == Double(id) { throw LocalPlaybackError.subtitleTrackConflict }
        try await selectTrack(id: id, kind: .subtitle)
    }

    /// Applies formatting without pausing, seeking, or reloading media. Once the
    /// bounded batch is submitted, wait for its acknowledgements even if its
    /// caller cancels so the snapshot describes the actual accepted settings.
    /// Closing/replacing media still interrupts it through the generation guard.
    public func applySubtitlePresentation(_ presentation: SubtitlePresentation) async throws {
        try Task.checkCancellation()
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        guard snapshot.loaded else { throw LocalPlaybackError.noVideoFrame }
        guard !loading, !trackOperationInProgress, seatsix_mpv_pending_track_commands(handle) == 0 else { throw LocalPlaybackError.trackOperationInProgress }
        trackOperationInProgress = true
        defer { trackOperationInProgress = false }
        let operation = generation
        let normalized = presentation.normalized
        let completion = Task { @MainActor in
            try await self.setSubtitlePresentation(normalized, operation: operation)
            self.snapshot.subtitlePresentation = normalized
            self.onChange?()
        }
        try await completion.value
        try Task.checkCancellation()
    }

    private func setSubtitlePresentation(_ presentation: SubtitlePresentation, operation: UInt64) async throws {
        try ensureCurrent(operation)
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        let commands = presentation.mpvOptions.map { name, value in
            seatsix_mpv_track_command(handle, "set", name, value, nil)
        }
        try await wait(operation: operation) {
            var allCompleted = true
            for command in commands {
                if try !self.trackCommandCompleted(command) { allCompleted = false }
            }
            return allCompleted
        }
    }

    private func selectTrack(id: Int?, kind: LocalPlaybackTrack.Kind) async throws {
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        guard snapshot.loaded else { throw LocalPlaybackError.noVideoFrame }
        guard !loading, !trackOperationInProgress, seatsix_mpv_pending_track_commands(handle) == 0 else { throw LocalPlaybackError.trackOperationInProgress }
        let tracks = kind == .audio ? snapshot.audioTracks : snapshot.subtitleTracks
        guard (kind == .subtitle && id == nil) || tracks.contains(where: { $0.id == id }) else { throw LocalPlaybackError.invalidTrack }
        trackOperationInProgress = true
        defer { trackOperationInProgress = false }
        let operation = generation
        let command = seatsix_mpv_track_command(handle, "set", kind == .audio ? "aid" : "sid", id.map(String.init) ?? "no", nil)
        defer { if resources.handle == handle { seatsix_mpv_abort_track_command(handle, command) } }
        try await wait(operation: operation) {
            try self.trackCommandCompleted(command)
                && (kind == .audio ? self.snapshot.selectedAudioTrackID : self.snapshot.selectedSubtitleTrackID) == id
        }
    }

    /// The caller must obtain user approval for the local file (for example via
    /// NSOpenPanel). Copy bounded, validated text into an engine-owned directory
    /// before handing it to mpv, so later file replacement cannot change content.
    @discardableResult
    public func addExternalSubtitle(url: URL, title: String? = nil) async throws -> LocalPlaybackTrack {
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        guard snapshot.loaded else { throw LocalPlaybackError.noVideoFrame }
        guard !loading, !trackOperationInProgress, seatsix_mpv_pending_track_commands(handle) == 0 else { throw LocalPlaybackError.trackOperationInProgress }
        guard externalSubtitleCount < 32 else { throw LocalPlaybackError.subtitleTooLarge }
        trackOperationInProgress = true
        defer { trackOperationInProgress = false }
        let operation = generation
        let reader = subtitleReader
        // A local selection may live on SMB or another slow file provider.
        // Keep the actual read/validation off the rendering/UI actor. Await the
        // worker even when cancelled so callers retain security scope until its
        // descriptor is closed; do not pass cancelled results to mpv.
        let data = try await Task.detached(priority: .userInitiated) {
            try reader(url)
        }.value
        try Task.checkCancellation()
        try ensureCurrent(operation)
        if resources.subtitleDirectory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixSubtitles-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            resources.subtitleDirectory = directory
        }
        guard let directory = resources.subtitleDirectory else { throw LocalPlaybackError.invalidSubtitle }
        let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.lowercased())
        guard FileManager.default.createFile(atPath: copy.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LocalPlaybackError.invalidSubtitle }
        externalSubtitleCount += 1
        let previous = Set(snapshot.subtitleTracks.map(\.id))
        let displayTitle = String((title ?? url.deletingPathExtension().lastPathComponent)
            .filter { character in character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }.prefix(200))
        // Keep cancellable file opening separate from subtitle selection. In
        // mpv 0.41, cancelling sub-add(select) while it synchronously preloads
        // the new track can leave the cancelled demuxer spinning in preload.
        // auto adds without selecting; only a completed add may be selected.
        let command = seatsix_mpv_track_command(handle, "sub-add", copy.path, "auto", displayTitle)
        defer { if resources.handle == handle { seatsix_mpv_abort_track_command(handle, command) } }
        try await wait(operation: operation) {
            try self.trackCommandCompleted(command) && self.snapshot.subtitleTracks.contains {
                !previous.contains($0.id) && $0.isExternal
            }
        }
        guard let track = snapshot.subtitleTracks.first(where: { !previous.contains($0.id) && $0.isExternal }) else { throw LocalPlaybackError.invalidTrack }
        try ensureCurrent(operation)
        let selection = seatsix_mpv_track_command(handle, "set", "sid", String(track.id), nil)
        defer { if resources.handle == handle { seatsix_mpv_abort_track_command(handle, selection) } }
        try await wait(operation: operation) {
            try self.trackCommandCompleted(selection) && self.snapshot.selectedSubtitleTrackID == track.id
        }
        return track
    }

    nonisolated public static func validatedSubtitleData(url: URL) throws -> Data {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host), [url.user, url.password].allSatisfy({ $0 == nil }),
              url.query == nil, url.fragment == nil,
              ["srt", "ass", "ssa", "vtt"].contains(url.pathExtension.lowercased()) else { throw LocalPlaybackError.invalidSubtitle }
        // Inspect the opened descriptor, not path metadata, to prevent a file
        // replacement race from turning an approved subtitle into a pipe/device.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LocalPlaybackError.invalidSubtitle }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0 else { throw LocalPlaybackError.invalidSubtitle }
        let limit = 10 * 1024 * 1024
        guard attributes.st_size <= limit else { throw LocalPlaybackError.subtitleTooLarge }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw LocalPlaybackError.subtitleTooLarge }
        var text = String(data: bytes, encoding: .utf8)
        if text == nil, bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { text = String(data: bytes, encoding: .utf16) }
        guard var text else { throw LocalPlaybackError.invalidSubtitle }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }),
              !text.contains("#EXTM3U"), !text.contains("#EXT-X-"), !text.contains("ffconcat version"), !text.contains("[playlist]") else { throw LocalPlaybackError.invalidSubtitle }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCue = text.range(of: #"(?m)^\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s+-->\s+\d{1,2}:\d{2}:\d{2}[,.]\d{3}"#, options: .regularExpression) != nil
        switch url.pathExtension.lowercased() {
        case "srt":
            guard trimmed.range(of: #"^\d+[ \t]*\n\d{1,2}:\d{2}:\d{2},\d{3}\s+-->"#, options: .regularExpression) != nil, hasCue else { throw LocalPlaybackError.invalidSubtitle }
        case "vtt":
            guard trimmed.hasPrefix("WEBVTT\n") || trimmed.hasPrefix("WEBVTT "),
                  hasCue || text.range(of: #"(?m)^\d{2}:\d{2}\.\d{3}\s+-->\s+\d{2}:\d{2}\.\d{3}"#, options: .regularExpression) != nil else { throw LocalPlaybackError.invalidSubtitle }
        default:
            guard trimmed.hasPrefix("[Script Info]"), text.contains("[Events]"), text.contains("Format:"),
                  text.range(of: #"(?m)^Dialogue:\s*[^\n]+"#, options: .regularExpression) != nil else { throw LocalPlaybackError.invalidSubtitle }
        }
        return Data(text.utf8)
    }

    private func trackCommandCompleted(_ identifier: UInt64) throws -> Bool {
        guard let handle = resources.handle else { throw LocalPlaybackError.closed }
        var error: Int32 = 0
        let complete = seatsix_mpv_track_command_result(handle, identifier, &error) != 0
        if complete { try check(error) }
        return complete
    }

    public func shutdown() {
        generation &+= 1
        seekGeneration &+= 1
        pollTask?.cancel(); pollTask = nil
        onChange = nil
        resources.close()
        adjustments.removeAll()
        snapshot.loaded = false
        snapshot.displayAspectRatio = nil
        snapshot.paused = true
        snapshot.buffering = false
        snapshot.seeking = false
        snapshot.chapters = []
        snapshot.audioTracks = []
        snapshot.subtitleTracks = []
        snapshot.selectedAudioTrackID = nil
        snapshot.selectedSubtitleTrackID = nil
        snapshot.subtitleText = nil
    }

    public func captureFrameEvidence() throws -> DecodedFrameEvidence {
        let (width, height, bytes) = try capturePixels()
        let nonBlack = stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + (max(bytes[$1], bytes[$1 + 1], bytes[$1 + 2]) > 8 ? 1 : 0) }
        return DecodedFrameEvidence(width: snapshot.videoWidth, height: snapshot.videoHeight, sampleWidth: width, sampleHeight: height, sampleSHA256: SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(), nonBlackPixelCount: nonBlack)
    }

    /// Render the active decoded frame into a small independent image without
    /// capturing another app or changing the visible video surface.
    public func thumbnailImage() throws -> NSImage {
        let (width, height, bytes) = try capturePixels()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw LocalPlaybackError.noVideoFrame }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private func capturePixels() throws -> (Int, Int, [UInt8]) {
        guard snapshot.loaded, snapshot.videoWidth > 0, snapshot.videoHeight > 0, let handle = resources.handle else { throw LocalPlaybackError.noVideoFrame }
        let scale = min(1, 320 / Double(max(snapshot.videoWidth, snapshot.videoHeight)))
        let width = max(1, Int((Double(snapshot.videoWidth) * scale).rounded()))
        let height = max(1, Int((Double(snapshot.videoHeight) * scale).rounded()))
        let context = resources.context
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext() }
        var framebuffer: GLuint = 0, texture: GLuint = 0
        glGenFramebuffers(1, &framebuffer)
        glGenTextures(1, &texture)
        defer { glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0); glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture) }
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw LocalPlaybackError.noVideoFrame }
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        try check(seatsix_mpv_render(handle, Int32(framebuffer), Int32(width), Int32(height), 0))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &bytes)
        guard glGetError() == GLenum(GL_NO_ERROR) else { throw LocalPlaybackError.noVideoFrame }
        return (width, height, bytes)
    }

    private func wait(operation: UInt64, until condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            try Task.checkCancellation()
            try ensureCurrent(operation)
            tick()
            if snapshot.failure != nil { throw LocalPlaybackError.decodingFailed(-1) }
            if try condition() { return }
            guard ContinuousClock.now < deadline else { throw LocalPlaybackError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func ensureCurrent(_ operation: UInt64) throws {
        guard resources.handle != nil else { throw LocalPlaybackError.closed }
        guard operation == generation else { throw LocalPlaybackError.superseded }
    }
    private func check(_ result: Int32) throws { if result < 0 { throw LocalPlaybackError.decodingFailed(result) } }
    private func number(_ property: String, fallback: Double = 0) -> Double {
        guard let handle = resources.handle else { return fallback }
        var value: Double = 0
        return seatsix_mpv_double(handle, property, &value) >= 0 && value.isFinite ? value : fallback
    }
    private func flag(_ property: String) -> Bool {
        guard let handle = resources.handle else { return false }
        var value: Int32 = 0
        return seatsix_mpv_flag(handle, property, &value) >= 0 && value != 0
    }
    private func string(_ property: String) -> String? {
        guard let handle = resources.handle, let value = seatsix_mpv_string(handle, property) else { return nil }
        defer { seatsix_mpv_free_string(value) }
        return String(cString: value)
    }
    private func drainEvents() {
        guard let handle = resources.handle else { return }
        for _ in 0..<100 {
            let event = seatsix_mpv_poll(handle)
            switch event.kind {
            case 0: return
            case 1: snapshot.loaded = true
            case 2: snapshot.ended = true; snapshot.paused = true
            case 3: snapshot.failure = LocalPlaybackError.decodingFailed(event.error).localizedDescription; snapshot.buffering = false
            case 5: restarts &+= 1
            case 6: snapshot.failure = LocalPlaybackError.closed.localizedDescription
            case 8: stopReplies &+= 1
            case 9: snapshot.chapters = readChapters()
            default: break
            }
        }
    }
    private func tick(afterSeek: Bool = false) {
        guard let handle = resources.handle else { return }
        let old = snapshot
        drainEvents()
        snapshot.seconds = max(0, number("time-pos", fallback: snapshot.seconds))
        let duration = number("duration")
        snapshot.duration = duration > 0 ? duration : nil
        snapshot.paused = flag("pause")
        snapshot.playbackRate = number("speed", fallback: snapshot.playbackRate)
        snapshot.audioPitchCorrectionEnabled = flag("audio-pitch-correction")
        snapshot.buffering = snapshot.failure == nil && (!snapshot.loaded || flag("paused-for-cache"))
        snapshot.ended = (!afterSeek && snapshot.ended) || flag("eof-reached")
        snapshot.videoWidth = Int(min(32768, max(0, number("video-params/w"))))
        snapshot.videoHeight = Int(min(32768, max(0, number("video-params/h"))))
        let aspectRatio = number("video-out-params/aspect")
        let rotation = number("video-out-params/rotate")
        if snapshot.loaded && aspectRatio > 0 {
            snapshot.displayAspectRatio = rotation == 90 || rotation == 270 ? 1 / aspectRatio : aspectRatio
        } else {
            snapshot.displayAspectRatio = nil
        }
        snapshot.videoCodec = string("video-format")
        snapshot.audioCodec = string("audio-codec-name")
        snapshot.hardwareDecoder = string("hwdec-current")
        let sampleRate = number("audio-out-params/samplerate")
        snapshot.audioSampleRate = sampleRate > 0 && sampleRate <= 768000 ? Int(sampleRate) : nil
        let channels = number("audio-out-params/channel-count")
        snapshot.audioChannels = channels > 0 && channels <= 256 ? Int(channels) : nil
        let audioPTS = number("audio-pts", fallback: -1)
        snapshot.audioPTS = audioPTS >= 0 ? audioPTS : nil
        snapshot.audioOutput = string("current-ao")
        snapshot.inputBytesPerSecond = max(0, number("cache-speed"))
        var tracks: [LocalPlaybackTrack] = []
        for index in 0..<seatsix_mpv_track_count(handle) {
            var track = seatsix_mpv_track()
            guard seatsix_mpv_track_at(handle, index, &track) != 0, let type = track.type else { continue }
            let name = String(cString: type)
            guard name == "audio" || name == "sub", track.id > 0, track.id <= Int.max else { continue }
            tracks.append(LocalPlaybackTrack(id: Int(track.id), kind: name == "audio" ? .audio : .subtitle,
                title: track.title.map(String.init(cString:)), language: track.language.map(String.init(cString:)),
                codec: track.codec.map(String.init(cString:)), isDefault: track.is_default != 0, isForced: track.forced != 0,
                isExternal: track.external != 0, channelCount: track.channels > 0 ? Int(track.channels) : nil))
        }
        snapshot.audioTracks = tracks.filter { $0.kind == .audio }
        snapshot.subtitleTracks = tracks.filter { $0.kind == .subtitle }
        snapshot.selectedAudioTrackID = string("aid").flatMap(Int.init)
        snapshot.selectedSubtitleTrackID = string("sid").flatMap(Int.init)
        snapshot.subtitleText = string("sub-text")
        if old != snapshot { onChange?() }
    }

    private func renderUpdate() {
        // Metadata/events may arrive together with the first frame. Refresh the
        // cached snapshot before sizing an offscreen target, without core waits.
        tick()
        guard let handle = resources.handle else { return }
        resources.context.makeCurrentContext()
        if seatsix_mpv_render_update(handle) != 0 {
            if surface.window == nil, snapshot.videoWidth > 0 { _ = try? captureFrameEvidence() }
            else { surface.needsDisplay = true }
        }
        NSOpenGLContext.clearCurrentContext()
    }
}

private final class MPVVideoView: NSOpenGLView {
    fileprivate var resources: MPVResources?
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let resources, let handle = resources.handle else { return }
        resources.context.makeCurrentContext()
        let size = convertToBacking(bounds).size
        _ = seatsix_mpv_render(handle, 0, Int32(max(1, size.width)), Int32(max(1, size.height)), 1)
        resources.context.flushBuffer()
        NSOpenGLContext.clearCurrentContext()
    }
    override func reshape() { super.reshape(); needsDisplay = true }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
