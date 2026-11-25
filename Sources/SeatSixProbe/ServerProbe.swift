import AVFoundation
import Foundation
import SeatSixCore

/// Developer integration runner. Configuration and catalog reports belong in ignored .runtime/.
/// A fingerprint must only be supplied after the operator has confirmed that exact certificate.
@MainActor
enum ServerProbeRunner {
    private struct Configuration: Decodable {
        var kind: ServerKind
        var address: String
        var username: String
        var password: String
        var compatibilityMode: Bool
        var approvedFingerprint: String?
    }

    static func run(arguments: [String]) async {
        guard arguments.count >= 3, ["inspect", "inventory", "play", "play-local", "tracks", "experience", "series-play", "library-catalog", "user-state"].contains(arguments[0]) else {
            print("Usage: SeatSixProbe --server inspect|inventory|play|play-local|tracks|experience|series-play|library-catalog CONFIG REPORT [ITEM_ID or PRIVATE_CATALOG_REPORT]; user-state CONFIG REPORT MOVIE_ID SERIES_ID")
            exit(2)
        }
        let reportURL = URL(fileURLWithPath: arguments[2])
        var report: [String: Any] = ["success": false, "operation": arguments[0], "generatedAt": ISO8601DateFormatter().string(from: Date())]
        do {
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            guard let address = URL(string: config.address) else { throw ProbeFailure(message: "服务器地址无效") }
            var pin: CertificatePin?
            if arguments[0] == "inspect" || config.approvedFingerprint != nil {
                let inspection = try await CertificateInspector.inspect(url: address)
                if arguments[0] == "inspect" {
                    report["certificate"] = ["origin": inspection.origin, "subject": inspection.subject, "issuer": inspection.issuer,
                                             "sha256": inspection.sha256Fingerprint, "canApprove": inspection.canApprove,
                                             "systemTrusted": inspection.systemTrusted,
                                             "validFrom": inspection.validFrom.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                                             "validUntil": inspection.validUntil.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                                             "explanation": inspection.trustFailureDescription ?? ""]
                    report["success"] = true
                    try write(report, to: reportURL)
                    print("Credential-free certificate inspection complete; details saved to the local report.")
                    return
                }
                guard config.approvedFingerprint == inspection.sha256Fingerprint else { throw CertificateTrustError.certificateChanged }
                pin = try inspection.makePin()
            }
            let deviceID = "seatsix-private-server-probe"
            var authentication = try await MediaServerClient.authenticate(kind: config.kind, address: config.address, username: config.username,
                password: config.password, allowInsecureHTTP: true, deviceID: deviceID, compatibilityMode: config.compatibilityMode, certificatePin: pin)
            var client = MediaServerClient(connection: authentication.connection, token: authentication.token, deviceID: deviceID)
            let libraries = try await client.libraries()
            report["loginPassed"] = true
            report["libraryCount"] = libraries.count
            authentication.connection.libraryIDs = libraries.map(\.id)
            client = MediaServerClient(connection: authentication.connection, token: authentication.token, deviceID: deviceID)
            if arguments[0] == "user-state" {
                guard arguments.count == 5 else { throw ProbeFailure(message: "收藏与观看状态验收必须明确指定一部未看电影和一部剧集") }
                let initialReport = report
                let result = await UserStateProbe.verify(client: client, token: authentication.token, libraries: libraries,
                    movieID: arguments[3], seriesID: arguments[4], persist: { progress in
                        var intermediate = initialReport
                        for (key, value) in progress { intermediate[key] = value }
                        try write(intermediate, to: reportURL)
                    })
                for (key, value) in result { report[key] = value }
                guard result["passed"] as? Bool == true else {
                    throw ProbeFailure(message: "收藏与观看状态验收未全部通过；恢复结果及失败步骤已保存到匿名报告")
                }
            } else if arguments[0] == "library-catalog" {
                guard (3...4).contains(arguments.count) else { throw ProbeFailure(message: "媒体库验收参数数量无效") }
                let result = try await LibraryCatalogProbe.verify(client: client, libraries: libraries)
                for (key, value) in result.report { report[key] = value }
                if arguments.count == 4 {
                    let privateURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
                    guard privateURL.pathComponents.contains(".runtime") else {
                        throw ProbeFailure(message: "包含影片名称的界面验收辅助记录只能保存在忽略的 .runtime 目录")
                    }
                    try write(result.privateReport, to: privateURL)
                }
                guard result.report["passed"] as? Bool == true else {
                    throw ProbeFailure(message: "完整媒体库搜索、筛选或排序未取得全部通过证据，详见匿名报告")
                }
            } else if arguments[0] == "inventory" {
                var catalog: [[String: Any]] = []
                for library in libraries {
                    let page = try await client.items(libraryID: library.id)
                    catalog.append(["id": library.id, "name": library.name, "loadedCount": page.items.count,
                        "items": page.items.map { item -> [String: Any] in
                            ["id": item.id, "name": item.name, "type": item.type, "resumeTicks": item.userData.playbackPositionTicks,
                             "sources": item.mediaSources.map { source -> [String: Any] in
                                ["id": source.id, "container": source.container ?? "", "streams": (source.mediaStreams ?? []).map { ["type": $0.type ?? "", "codec": $0.codec ?? ""] }]
                             }]
                        }])
                }
                report["libraries"] = catalog
            } else {
                guard arguments.count == 4 else { throw ProbeFailure(message: "播放验证必须明确指定影片 ID") }
                let item = try await client.item(id: arguments[3])
                guard item.isPlayable || (arguments[0] == "series-play" && item.type == "Series") else { throw ProbeFailure(message: "所选条目不是可播放影片或剧集") }
                let result: [String: Any]
                switch arguments[0] {
                case "tracks": result = try await TrackProbe.verify(client: client, item: item)
                case "play-local": result = try await LocalDecoderProbe.verify(client: client, item: item)
                case "experience": result = try await PlaybackExperienceProbe.verify(client: client, item: item)
                case "series-play": result = try await SeriesPlaybackProbe.verify(client: client, series: item)
                default: result = try await verifyPlayback(client: client, item: item, pin: pin)
                }
                for (key, value) in result { report[key] = value }
                if arguments[0] == "experience", result["passed"] as? Bool != true {
                    throw ProbeFailure(message: "部分倍速、音视频推进或续播未取得完整证据；已保存诊断结果，不能判定通过")
                }
                if arguments[0] == "tracks", (result["subtitlePresentation"] as? [String: Any])?["passed"] as? Bool != true {
                    throw ProbeFailure(message: "部分字幕延迟或样式尚未取得实际画面证据；已保存诊断结果，不能判定全部通过")
                }
                if arguments[0] == "tracks", result["embeddedRenderingPassed"] as? Bool != true {
                    throw ProbeFailure(message: "部分内嵌字幕未在有限采样范围内找到可见字幕帧；其余验证证据已保存，不能判定全部通过")
                }
            }
            report["success"] = true
            print("Server \(arguments[0]) passed; private details saved only to the local report.")
        } catch {
            let safe: String
            if let known = error as? MediaServerError { safe = known.localizedDescription }
            else if let known = error as? CertificateTrustError { safe = known.localizedDescription }
            else if let known = error as? ProbeFailure { safe = known.message }
            else { safe = "验证未通过；不输出可能含认证地址的底层错误" }
            report["message"] = safe
            print(safe)
        }
        do { try write(report, to: reportURL) }
        catch { print("Unable to save the private verification report."); exit(1) }
        if report["success"] as? Bool != true { exit(1) }
    }

    private static func verifyPlayback(client: MediaServerClient, item: MediaItem, pin: CertificatePin?) async throws -> [String: Any] {
        // Honor the existing viewing position; test only a few seconds and never mark watched explicitly.
        let originalTicks = item.userData.playbackPositionTicks
        let plan = try await client.playbackPlan(item: item, startTicks: originalTicks)
        let relay = pin.map { PinnedPlaybackRelay(sourceURL: plan.url, serverURL: client.connection.baseURL, certificatePin: $0) }
        var player: AVPlayer?
        var secondPlayer: AVPlayer?
        var secondRelay: PinnedPlaybackRelay?
        var secondPlan: PlaybackPlan?
        do {
            let url = try await relay?.start() ?? plan.url
            let first = try await SeatSixProbe.playAndDecode(plan: plan, playbackURL: url)
            player = first.player
            let reporter = PlaybackReporter(client: client, plan: plan)
            try await reporter.start(positionTicks: ticks(first.player))
            try await Task.sleep(for: .seconds(2))
            try await reporter.progress(positionTicks: ticks(first.player), isPaused: false)
            first.player.pause()
            let stoppedTicks = ticks(first.player)
            try await reporter.stop(positionTicks: stoppedTicks)
            first.player.replaceCurrentItem(with: nil)
            await relay?.stop()
            try await client.stopTranscoding(plan: plan)
            let remote = try await client.item(id: item.id)
            let remoteTicks = remote.userData.playbackPositionTicks
            guard abs(remoteTicks - stoppedTicks) <= 20_000_000 else { throw ProbeFailure(message: "停止上报后服务器进度不一致") }
            let nextPlan = try await client.playbackPlan(item: remote, startTicks: remoteTicks)
            secondPlan = nextPlan
            secondRelay = pin.map { PinnedPlaybackRelay(sourceURL: nextPlan.url, serverURL: client.connection.baseURL, certificatePin: $0) }
            let nextURL = try await secondRelay?.start() ?? nextPlan.url
            let second = try await SeatSixProbe.playAndDecode(plan: nextPlan, playbackURL: nextURL)
            secondPlayer = second.player
            let nextReporter = PlaybackReporter(client: client, plan: nextPlan)
            try await nextReporter.start(positionTicks: ticks(second.player))
            second.player.pause()
            let finalTicks = ticks(second.player)
            try await nextReporter.stop(positionTicks: finalTicks)
            second.player.replaceCurrentItem(with: nil)
            await secondRelay?.stop()
            try await client.stopTranscoding(plan: nextPlan)
            let finalRemote = try await client.item(id: item.id)
            guard abs(finalRemote.userData.playbackPositionTicks - finalTicks) <= 20_000_000 else { throw ProbeFailure(message: "第二次停止上报后服务器进度不一致") }
            return ["actualMethod": plan.method.rawValue, "frameWidth": first.width, "frameHeight": first.height,
                    "playbackAdvancedSeconds": first.advance, "originalSeconds": Double(originalTicks) / 10_000_000,
                    "savedSeconds": Double(stoppedTicks) / 10_000_000, "remoteSeconds": Double(remoteTicks) / 10_000_000,
                    "resumedSeconds": second.startSeconds, "finalRemoteSeconds": Double(finalRemote.userData.playbackPositionTicks) / 10_000_000,
                    "pinnedTransport": pin != nil]
        } catch {
            player?.pause(); player?.replaceCurrentItem(with: nil)
            secondPlayer?.pause(); secondPlayer?.replaceCurrentItem(with: nil)
            await relay?.stop(); await secondRelay?.stop()
            try? await client.stopTranscoding(plan: plan)
            if let secondPlan { try? await client.stopTranscoding(plan: secondPlan) }
            throw error
        }
    }

    private static func ticks(_ player: AVPlayer) -> Int64 {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(max(0, min(seconds, 1_000_000_000)) * 10_000_000) : 0
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try PrivateReportWriter.write(data, to: url)
    }
}
