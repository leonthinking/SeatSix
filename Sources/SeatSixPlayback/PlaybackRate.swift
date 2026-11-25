import Foundation

public enum PlaybackRate {
    public static let allowedRange: ClosedRange<Double> = 0.5...2
    public static let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    public static func validate(_ rate: Double) throws {
        guard rate.isFinite, allowedRange.contains(rate) else { throw LocalPlaybackError.invalidPlaybackRate }
    }
}
