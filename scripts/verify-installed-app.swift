import AppKit
import CoreGraphics
import Foundation

enum InstallError: Error {
    case arguments, unexpectedBundle, missingWindow, failedToQuit
}

@main
struct InstalledAppCheck {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw InstallError.arguments }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let profile = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try FileManager.default.createDirectory(
            at: profile.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true
        )
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = true
        options.activates = true
        options.environment = ["CFFIXED_USER_HOME": profile.path]
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: options)
        guard app.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() else {
            throw InstallError.unexpectedBundle
        }
        defer { if !app.isTerminated { app.terminate() } }
        var consecutive = 0
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(250))
            if app.isTerminated { throw InstallError.missingWindow }
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []
            let hasWindow = windows.contains { window in
                guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }
                return (bounds["Width"] ?? 0) > 200 && (bounds["Height"] ?? 0) > 150
            }
            consecutive = hasWindow ? consecutive + 1 : 0
            if consecutive == 5 { break }
        }
        guard consecutive == 5 else { throw InstallError.missingWindow }
        guard app.terminate() else { throw InstallError.failedToQuit }
        for _ in 0..<100 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        guard app.isTerminated else { throw InstallError.failedToQuit }
        print("Installed SeatSix opened a native window in five consecutive observations and quit normally.")
    }
}
