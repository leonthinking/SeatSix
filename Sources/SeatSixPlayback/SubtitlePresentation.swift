import Foundation

/// Text size uses mpv's 720-pixel reference canvas. Positive delay means the
/// subtitle appears later; bitmap subtitles support timing but not text styling.
public struct SubtitlePresentation: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case original, outlined, boxed, yellow
    }

    public var delaySeconds: Double
    public var fontSize: Double
    public var style: Style

    public init(delaySeconds: Double = 0, fontSize: Double = 48, style: Style = .original) {
        self.delaySeconds = delaySeconds
        self.fontSize = fontSize
        self.style = style
    }

    public var normalized: Self {
        Self(delaySeconds: delaySeconds.isFinite ? min(30, max(-30, delaySeconds)) : 0,
             fontSize: fontSize.isFinite ? min(72, max(24, fontSize)) : 48,
             style: style)
    }

    // Keep these options explicit so returning to Original also removes every
    // override from another preset. No option changes playback or subtitle tracks.
    var mpvOptions: [(String, String)] {
        let value = normalized
        return [
            ("sub-delay", String(value.delaySeconds)),
            ("sub-ass-override", value.style == .original ? "scale" : "force"),
            ("sub-font-size", value.style == .original ? "48" : String(value.fontSize)),
            ("sub-scale", value.style == .original ? String(value.fontSize / 48) : "1"),
            ("sub-color", value.style == .yellow ? "1/0.9/0/1" : "1/1/1/1"),
            ("sub-outline-color", "0/0/0/1"),
            ("sub-outline-size", value.style == .boxed ? "0" : "1.65"),
            ("sub-border-style", value.style == .boxed ? "background-box" : "outline-and-shadow"),
            ("sub-back-color", value.style == .boxed ? "0/0/0/0.75" : "0/0/0/0"),
            ("sub-shadow-offset", value.style == .boxed ? "4" : "0")
        ]
    }
}
