import AVFoundation
import CoreVideo
import Foundation
import SeatSixCore

private struct Credential: Decodable {
    var username: String
    var password: String
    var url: String
    var version: String?
}

private struct ProbeResult: Codable {
    var server: String
    var version: String?
    var mode: String
    var success: Bool
    var message: String
    var actualMethod: String?
    var frameWidth: Int?
    var frameHeight: Int?
    var playbackAdvancedSeconds: Double?
    var savedSeconds: Double?
    var remoteSeconds: Double?
    var resumedSeconds: Double?
}

private struct ProbeReport: Codable {
    var generatedAt: String
    var cases: [ProbeResult]
}

struct ProbeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Existing integration volumes may still contain the fixtures created before the rename.
func preferredFixture<Element>(_ elements: [Element], named suffix: String, name: KeyPath<Element, String>) -> Element? {
    elements.first { $0[keyPath: name] == "SeatSix " + suffix }
        ?? elements.first { $0[keyPath: name] == "Theater " + suffix }
}

@main
struct SeatSixProbe {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--local-files" {
            await LocalDecoderProbe.verifyFiles(arguments: Array(arguments.dropFirst(2)))
            return
        }
        if arguments.dropFirst().first == "--server" {
            await ServerProbeRunner.run(arguments: Array(arguments.dropFirst(2)))
            return
        }
        let credentialPath = arguments.count > 1 ? arguments[1] : ".runtime/test-credentials.json"
        let reportPath = arguments.count > 2 ? arguments[2] : ".runtime/probe-results.json"
        var results: [ProbeResult] = []
        do {
            let credentials = try JSONDecoder().decode([String: Credential].self, from: Data(contentsOf: URL(fileURLWithPath: credentialPath)))
            for kind in ServerKind.allCases {
                guard let credential = credentials[kind.rawValue] else { continue }
                do {
                    let deviceID = "seatsix-probe-\(kind.rawValue)"
                    var authentication = try await MediaServerClient.authenticate(kind: kind, address: credential.url, username: credential.username, password: credential.password, allowInsecureHTTP: true, deviceID: deviceID)
                    let preselection = MediaServerClient(connection: authentication.connection, token: authentication.token, deviceID: deviceID)
                    let libraries = try await preselection.libraries()
                    guard let library = preferredFixture(libraries, named: "Test Movies", name: \.name) else { throw ProbeFailure(message: "测试媒体库未出现") }
                    authentication.connection.libraryIDs = [library.id]
                    let client = MediaServerClient(connection: authentication.connection, token: authentication.token, deviceID: deviceID)
                    let page = try await client.items(libraryID: library.id)
                    for mode in PlaybackMode.allCases {
                        let titleSuffix = mode == .automatic ? "Direct Test" : "Compatibility Test"
                        do {
                            guard let item = preferredFixture(page.items, named: titleSuffix, name: \.name) else { throw ProbeFailure(message: "人工测试影片未出现在媒体库") }
                            let result = try await probe(client: client, item: item, kind: kind, version: credential.version, mode: mode)
                            results.append(result)
                            print("\(kind.name) \(mode.rawValue): passed (decoded frame + playback advance + server progress + fresh-player resume)")
                        } catch {
                            let safe = safeMessage(error)
                            results.append(ProbeResult(server: kind.rawValue, version: credential.version, mode: mode.rawValue, success: false, message: safe))
                            print("\(kind.name) \(mode.rawValue): failed — \(safe)")
                        }
                    }
                } catch {
                    let safe = safeMessage(error)
                    results.append(ProbeResult(server: kind.rawValue, version: credential.version, mode: "login-library", success: false, message: safe))
                    print("\(kind.name): failed — \(safe)")
                }
            }
        } catch {
            results.append(ProbeResult(server: "configuration", mode: "read-credentials", success: false, message: "无法读取本地测试凭据配置"))
            print("Unable to read local probe configuration.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let report = ProbeReport(generatedAt: ISO8601DateFormatter().string(from: Date()), cases: results)
            try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        } catch { print("Unable to write probe report."); exit(1) }
        if results.isEmpty || results.contains(where: { !$0.success }) { exit(1) }
    }

    @MainActor
    private static func probe(client: MediaServerClient, item: MediaItem, kind: ServerKind, version: String?, mode: PlaybackMode) async throws -> ProbeResult {
        let detail = try await client.item(id: item.id)
        let plan = try await client.playbackPlan(item: detail, mode: mode, startTicks: 750_000_000)
        if mode == .automatic && plan.method != .directPlay { throw ProbeFailure(message: "MP4 样片未协商为原始直放") }
        if mode == .compatible && !plan.isTranscoding { throw ProbeFailure(message: "兼容样片未协商为 HLS 转码") }
        let first = try await playAndDecode(plan: plan)
        let reporter = PlaybackReporter(client: client, plan: plan)
        do {
            try await reporter.start(positionTicks: ticks(first.player.currentTime().seconds))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await reporter.progress(positionTicks: ticks(first.player.currentTime().seconds), isPaused: false)
            first.player.pause()
            let finalTicks = ticks(first.player.currentTime().seconds)
            try await reporter.stop(positionTicks: finalTicks)
            first.player.replaceCurrentItem(with: nil)
            try await client.stopTranscoding(plan: plan)
            let remote = try await client.item(id: item.id)
            let serverTicks = remote.userData.playbackPositionTicks
            guard abs(serverTicks - finalTicks) <= 20_000_000 else { throw ProbeFailure(message: "服务器续播位置与成功上报位置不一致") }
            let secondPlan = try await client.playbackPlan(item: remote, mode: mode, startTicks: serverTicks)
            let second = try await playAndDecode(plan: secondPlan)
            let secondReporter = PlaybackReporter(client: client, plan: secondPlan)
            do {
                try await secondReporter.start(positionTicks: ticks(second.player.currentTime().seconds))
                second.player.pause()
                try await secondReporter.stop(positionTicks: ticks(second.player.currentTime().seconds))
                second.player.replaceCurrentItem(with: nil)
                try await client.stopTranscoding(plan: secondPlan)
            } catch {
                second.player.pause(); second.player.replaceCurrentItem(with: nil)
                try? await client.stopTranscoding(plan: secondPlan)
                throw error
            }
            return ProbeResult(server: kind.rawValue, version: version, mode: mode.rawValue, success: true, message: "真实 AVPlayer 像素帧、时间前进、进度回写与新播放器续播均通过", actualMethod: plan.method.rawValue, frameWidth: first.width, frameHeight: first.height, playbackAdvancedSeconds: first.advance, savedSeconds: Double(finalTicks) / 10_000_000, remoteSeconds: Double(serverTicks) / 10_000_000, resumedSeconds: second.startSeconds)
        } catch {
            first.player.pause(); first.player.replaceCurrentItem(with: nil)
            try? await client.stopTranscoding(plan: plan)
            throw error
        }
    }

    @MainActor
    static func playAndDecode(plan: PlaybackPlan, playbackURL: URL? = nil) async throws -> (player: AVPlayer, width: Int, height: Int, advance: Double, startSeconds: Double) {
        let item = AVPlayerItem(url: playbackURL ?? plan.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        do {
            let readyDeadline = Date().addingTimeInterval(45)
            while item.status != .readyToPlay {
                if item.status == .failed { throw playerFailure(item) }
                guard Date() < readyDeadline else { throw ProbeFailure(message: "AVPlayer 资源准备超时") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let seconds = Double(plan.resumeTicks) / 10_000_000
            let seekSucceeded = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard seekSucceeded else { throw ProbeFailure(message: "AVPlayer seek 未完成") }
            let actualStart = player.currentTime().seconds
            guard actualStart.isFinite, abs(actualStart - seconds) <= 2 else { throw ProbeFailure(message: "AVPlayer 续播 seek 位置不正确") }
            player.play()
            let frameDeadline = Date().addingTimeInterval(35)
            var width = 0; var height = 0
            while Date() < frameDeadline {
                if item.status == .failed { throw playerFailure(item) }
                let time = player.currentTime()
                if let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { width = CVPixelBufferGetWidth(pixel); height = CVPixelBufferGetHeight(pixel) }
                let advance = time.seconds - actualStart
                if width > 0 && height > 0 && advance > 1.2 { return (player, width, height, advance, actualStart) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw ProbeFailure(message: "AVPlayer 未在时限内产出真实视频帧并前进")
        } catch { player.pause(); player.replaceCurrentItem(with: nil); throw error }
    }

    private static func ticks(_ seconds: Double) -> Int64 { seconds.isFinite ? Int64(max(0, min(seconds, 1_000_000_000)) * 10_000_000) : 0 }
    private static func safeMessage(_ error: Error) -> String {
        if let known = error as? MediaServerError { return known.localizedDescription }
        if let known = error as? ProbeFailure { return known.message }
        return "验证失败；底层错误详情未输出，以避免泄露认证地址"
    }
    private static func playerFailure(_ item: AVPlayerItem) -> ProbeFailure {
        // AVFoundation error userInfo can include authenticated URLs. Never print it.
        let code = (item.error as NSError?)?.code ?? 0
        return ProbeFailure(message: "AVPlayer 无法加载或解码资源（错误码 \(code)）")
    }
}
