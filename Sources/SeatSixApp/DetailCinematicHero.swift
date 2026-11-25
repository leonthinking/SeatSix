import AppKit
import SwiftUI

/// Keep the image crop independent of the synopsis. Expanding text adds scrollable
/// space below the picture instead of zooming into the people in the artwork.
struct DetailCinematicHero<Content: View>: View {
    let image: NSImage?
    let hasArtwork: Bool
    let viewport: CGSize
    let inset: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let imageHeight = min(viewport.width * 9 / 16, viewport.height * 0.83)
        let bottomFade = min(94, max(46, imageHeight * 0.105))
        // Before either poster or backdrop succeeds, the shared window palette
        // already has enough contrast for white text. Preserve its brightness.
        let scrim = Color.black.opacity(hasArtwork ? 0.64 : 0)
        VStack(spacing: 0) {
            Spacer(minLength: max(SeatSixSidebarMetrics.titlebarHeight, imageHeight * 0.62))
            content()
                .padding(.horizontal, inset)
                .padding(.bottom, bottomFade + 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    VStack(spacing: 0) {
                        scrim
                        LinearGradient(colors: [scrim, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottomFade)
                    }
                    .overlay(alignment: .top) {
                        let fade = min(140, imageHeight * 0.13)
                        LinearGradient(colors: [.clear, scrim], startPoint: .top, endPoint: .bottom)
                            .frame(height: fade).offset(y: -fade)
                    }
                    .accessibilityHidden(true).allowsHitTesting(false)
                }
        }
        .frame(minHeight: imageHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            GeometryReader { geometry in
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                    .frame(width: geometry.size.width, height: imageHeight, alignment: .top)
                    .clipped()
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: bottomFade)
                        }
                    }
            }
            .accessibilityHidden(true).allowsHitTesting(false)
        }
        .background(SeatSixSidebarGeometry(id: "detail-cinematic-hero"))
    }
}
