import Foundation
import SwiftUI

/// Shared navigation tones. Navigation surfaces protect their own labels
/// over the unmodified hues of the blurred poster.
enum SeatSixChrome {
    static let canvas = Color(red: 0.075, green: 0.085, blue: 0.105)
    static let navigation = Color(red: 0.15, green: 0.17, blue: 0.20)
    static let raised = Color(red: 0.12, green: 0.14, blue: 0.17)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.84)
    static let tertiaryText = Color.white.opacity(0.72)
    static let accent = Color(red: 0.65, green: 0.87, blue: 0.78)
}

enum SeatSixSurfaceRole: CaseIterable, Equatable {
    case navigation, toolbar, popover
}

/// A public, testable policy shared by broad navigation and compact controls.
/// Floating controls need a stronger fill than the already softened backdrop
/// under a sidebar, particularly when a bright poster passes behind them.
struct SeatSixSurfacePolicy: Equatable {
    let isOpaque: Bool
    let emphasizesBoundary: Bool
    let allowsAnimation: Bool
    let isActive: Bool

    init(reduceTransparency: Bool, increasedContrast: Bool, reduceMotion: Bool, isActive: Bool = true) {
        isOpaque = reduceTransparency || increasedContrast
        emphasizesBoundary = increasedContrast
        allowsAnimation = !reduceMotion
        self.isActive = isActive
    }

    func tintOpacity(for role: SeatSixSurfaceRole) -> Double {
        guard !isOpaque else { return 1 }
        switch role {
        case .navigation: return isActive ? 0.14 : 0.38
        case .toolbar: return isActive ? 0.82 : 0.90
        case .popover: return 0.94
        }
    }

    func edgeOpacity(for role: SeatSixSurfaceRole) -> Double {
        if emphasizesBoundary { return 0.65 }
        switch role {
        case .navigation: return isActive ? 0.10 : 0.07
        case .toolbar, .popover: return isActive ? 0.14 : 0.08
        }
    }
}

/// sRGB colour used to build a tiny, low-frequency field once per loaded hero.
/// Keeping the math independent from SwiftUI makes worst-case readability and
/// coloured/transparent artwork straightforward to verify.
struct SeatSixChromeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        func finiteUnit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.red = finiteUnit(red); self.green = finiteUnit(green); self.blue = finiteUnit(blue)
    }

    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func limitingLuminance(to ceiling: Double) -> Self {
        let luminance = relativeLuminance
        guard luminance > ceiling else { return self }
        let scale = ceiling / luminance
        func dim(_ channel: Double) -> Double {
            let linear = channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            let dimmed = linear * scale
            return dimmed <= 0.0031308 ? 12.92 * dimmed : 1.055 * pow(dimmed, 1 / 2.4) - 0.055
        }
        return Self(red: dim(red), green: dim(green), blue: dim(blue))
    }

}
