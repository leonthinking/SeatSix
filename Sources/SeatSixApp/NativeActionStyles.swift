import SwiftUI

struct NavigationToolbarIcon: View {
    let symbol: String

    var body: some View {
        // Older bordered buttons supply their own bezel insets. Glass encloses the whole label.
        let size: CGFloat = if #available(macOS 26, *) { 36 } else { 24 }
        return Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}

extension View {
    @ViewBuilder
    func seatSixGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Use the same system glass for icon buttons and the AppKit server selector.
    /// The native control inside the surface keeps its own focus, menu and hit target.
    @ViewBuilder
    func navigationControlGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
    }

    @ViewBuilder
    func navigationIconButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.plain).navigationControlGlass()
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}
