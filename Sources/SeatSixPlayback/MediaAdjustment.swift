import Foundation

/// Numeric selections exposed by the local player. Build mpv options only
/// from bounded values so files and UI text never become filter expressions.
public enum MediaAdjustment: Hashable, Sendable {
    case brightness, contrast, gamma, hue, saturation, rotation, mirror, aspect
    case audioDelay, channels, equalizer(Int), subtitlePosition, secondarySubtitle

    public static let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public var initial: Double { self == .subtitlePosition ? 100 : 0 }

    public var range: ClosedRange<Double> {
        switch self {
        case .rotation, .mirror, .channels: return 0...3
        case .aspect: return 0...4
        case .audioDelay: return -30...30
        case .equalizer: return -12...12
        case .subtitlePosition: return 0...100
        case .secondarySubtitle: return 0...Double(Int32.max)
        default: return -100...100
        }
    }

    func option(_ value: Double, previous: [Self: Double]) throws -> (String, String) {
        guard value.isFinite, range.contains(value),
              self == .audioDelay || value == value.rounded() else { throw AdjustmentError.outOfRange }
        let n = Int(value)
        switch self {
        case .brightness: return ("brightness", String(n))
        case .contrast: return ("contrast", String(n))
        case .gamma: return ("gamma", String(n))
        case .hue: return ("hue", String(n))
        case .saturation: return ("saturation", String(n))
        case .rotation: return ("video-rotate", String(n * 90))
        case .mirror: return ("vf", ["", "hflip", "vflip", "hflip,vflip"][n])
        case .aspect: return ("video-aspect-override", ["no", "16:9", "4:3", "2.35:1", "1:1"][n])
        case .audioDelay: return ("audio-delay", String(value))
        case .channels: return ("audio-channels", ["auto", "mono", "stereo", "5.1"][n])
        case .subtitlePosition: return ("sub-pos", String(n))
        case .secondarySubtitle: return ("secondary-sid", n == 0 ? "no" : String(n))
        case .equalizer(let index):
            guard Self.frequencies.indices.contains(index) else { throw AdjustmentError.outOfRange }
            let bands = Self.frequencies.enumerated().compactMap { i, frequency -> String? in
                let gain = i == index ? n : Int(previous[.equalizer(i)] ?? 0)
                return gain == 0 ? nil : "equalizer=f=\(frequency):width_type=o:width=1:g=\(gain)"
            }
            return ("af", bands.isEmpty ? "" : "lavfi=[\(bands.joined(separator: ","))]")
        }
    }

    enum AdjustmentError: LocalizedError {
        case outOfRange
        var errorDescription: String? { "此设置值超出范围。" }
    }
}
