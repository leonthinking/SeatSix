import AppKit
import SwiftUI

/// The playback dock follows the system's glass availability and readability preferences.
struct SeatSixMaterialPolicy: Equatable {
    enum Surface: Equatable { case liquidGlass, material, opaque }

    let surface: Surface
    let allowsAnimation: Bool
    let emphasizesBoundary: Bool

    init(supportsLiquidGlass: Bool, reduceTransparency: Bool, increasedContrast: Bool, reduceMotion: Bool) {
        surface = reduceTransparency || increasedContrast ? .opaque : (supportsLiquidGlass ? .liquidGlass : .material)
        allowsAnimation = !reduceMotion
        emphasizesBoundary = increasedContrast
    }
}

private struct PlaybackControlGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat
    let policyOverride: SeatSixMaterialPolicy?

    private var policy: SeatSixMaterialPolicy {
        if let policyOverride { return policyOverride }
        let supported: Bool
        if #available(macOS 26, *) { supported = true } else { supported = false }
        return SeatSixMaterialPolicy(supportsLiquidGlass: supported, reduceTransparency: reduceTransparency,
                                     increasedContrast: contrast == .increased, reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        surface(content)
            .transaction { transaction in
                if !policy.allowsAnimation {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if policy.surface == .opaque {
            content.background(SeatSixChrome.raised, in: shape)
                .overlay {
                    if policy.emphasizesBoundary {
                        shape.strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else if #available(macOS 26, *), policy.surface == .liquidGlass {
            // Keep the dimming beneath the glass so its highlights stay intact.
            content.glassEffect(.clear, in: shape)
                .background(.black.opacity(0.64), in: shape)
        } else {
            content.background(.black.opacity(0.25), in: shape)
                .background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func playbackControlGlass(cornerRadius: CGFloat, policyOverride: SeatSixMaterialPolicy? = nil) -> some View {
        modifier(PlaybackControlGlass(cornerRadius: cornerRadius, policyOverride: policyOverride))
    }

    func seatSixSurface(role: SeatSixSurfaceRole, cornerRadius: CGFloat = 12,
                        policyOverride: SeatSixSurfacePolicy? = nil) -> some View {
        modifier(SeatSixSurface(role: role, cornerRadius: cornerRadius, policyOverride: policyOverride))
    }
}

/// Large navigation surfaces use the root's low-frequency artwork rather than
/// another live blur. Compact controls add a public material under a bounded
/// tint, keeping labels readable even on a completely white hero.
private struct SeatSixSurface: ViewModifier {
    let role: SeatSixSurfaceRole
    let cornerRadius: CGFloat
    let policyOverride: SeatSixSurfacePolicy?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    private var policy: SeatSixSurfacePolicy {
        policyOverride ?? SeatSixSurfacePolicy(reduceTransparency: reduceTransparency,
                                               increasedContrast: contrast == .increased,
                                               reduceMotion: reduceMotion, isActive: activeState != .inactive)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if role == .navigation, !policy.isOpaque {
                        // The shared image is brightest near the titlebar. Back
                        // the sidebar's white rows locally and follow the image's fade.
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.70), location: 0),
                            .init(color: .black.opacity(0.55), location: 0.36),
                            .init(color: .clear, location: 0.82)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    if role != .navigation, !policy.isOpaque {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill((role == .navigation ? SeatSixChrome.navigation : SeatSixChrome.raised)
                        .opacity(policy.tintOpacity(for: role)))
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .trailing) {
                if role == .navigation {
                    Rectangle().fill(Color.white.opacity(policy.edgeOpacity(for: role))).frame(width: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    shape.strokeBorder(Color.white.opacity(policy.edgeOpacity(for: role)), lineWidth: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .transaction { transaction in
                if !policy.allowsAnimation {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
