// swift-tools-version: 5.9
import PackageDescription
import Foundation

#if arch(arm64)
let defaultBrewPrefix = "/opt/homebrew"
#else
let defaultBrewPrefix = "/usr/local"
#endif
let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? defaultBrewPrefix
let decoderPrefix = ProcessInfo.processInfo.environment["SEATSIX_DECODER_PREFIX"]
let mpvPrefix = decoderPrefix ?? (brewPrefix + "/opt/mpv")
let systemPlayer = ProcessInfo.processInfo.environment["SEATSIX_SYSTEM_PLAYER"] == "1"
let distributionBuild = systemPlayer || decoderPrefix != nil

let package = Package(
    name: "SeatSix",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeatSixCore", targets: ["SeatSixCore"]),
        .library(name: "SeatSixPlayback", targets: ["SeatSixPlayback"]),
        .executable(name: "SeatSix", targets: ["SeatSixApp"]),
        .executable(name: "SeatSixProbe", targets: ["SeatSixProbe"])
    ],
    targets: [
        .target(name: "SeatSixCore"),
        .target(name: "CMPV",
                exclude: [systemPlayer ? "CMPV.c" : "SystemPlayer.c"],
                cSettings: systemPlayer ? [] : [.unsafeFlags(["-I" + mpvPrefix + "/include"])],
                linkerSettings: systemPlayer ? [] : [.unsafeFlags(["-L" + mpvPrefix + "/lib"]),
                                                      .linkedLibrary("mpv"), .linkedFramework("OpenGL")]),
        .target(name: "SeatSixPlayback", dependencies: ["CMPV"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("OpenGL")]),
        .executableTarget(name: "SeatSixApp", dependencies: ["SeatSixCore", "SeatSixPlayback"],
                          exclude: distributionBuild ? ["Resources"] : [],
                          resources: distributionBuild ? [] : [.process("Resources")]),
        .executableTarget(name: "SeatSixProbe", dependencies: ["SeatSixCore", "SeatSixPlayback"]),
        .testTarget(name: "SeatSixPlaybackTests", dependencies: ["SeatSixPlayback"], path: "tests/SeatSixPlaybackTests"),
        .testTarget(name: "SeatSixCoreTests", dependencies: ["SeatSixCore"], path: "tests/SeatSixCoreTests"),
        .testTarget(name: "SeatSixAppTests", dependencies: ["SeatSixApp"], path: "tests/SeatSixAppTests",
                    swiftSettings: systemPlayer ? [.define("SEATSIX_SYSTEM_PLAYER")] : []),
        .testTarget(name: "SeatSixProbeTests", dependencies: ["SeatSixProbe"], path: "tests/SeatSixProbeTests")
    ],
    swiftLanguageVersions: [.v5]
)

// A development checkout can also contain an independent playback lab.
let labPath = "work/vidhub-player/20261118-local/replica"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if !distributionBuild, FileManager.default.fileExists(atPath: root.appendingPathComponent(labPath).path) {
    package.products.append(.executable(name: "SeatSixLab", targets: ["SeatSixLab"]))
    package.targets.append(.executableTarget(name: "SeatSixLab", dependencies: ["SeatSixCore", "SeatSixPlayback"],
                                             path: labPath))
    package.targets.append(.testTarget(name: "SeatSixLabTests", dependencies: ["SeatSixLab"], path: "tests/SeatSixLabTests"))
}
