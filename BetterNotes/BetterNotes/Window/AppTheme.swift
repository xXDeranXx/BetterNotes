import SwiftUI
import UIKit

/// The colors of the tab strip and the editor's top bar (pages always stay white). Chosen in
/// the toolbar settings and stored with `@AppStorage(AppTheme.settingKey)`, so it is the same
/// in every window. Each theme has a light and a dark variant.
nonisolated enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, blue, graphite, green

    static let settingKey = "appTheme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .graphite: "Graphite"
        case .green: "Green"
        }
    }

    /// Tinted themes have dark backgrounds in light mode too, so their text and icons are white.
    var isTinted: Bool { self != .system }

    /// Behind the tabs (and the status bar). The colors are picked for the window's light or dark
    /// mode by the caller, not resolved later by UIKit: the bar is drawn in a dark style for
    /// tinted themes (white icons), which would otherwise pick the dark shade for it alone.
    func stripColor(_ scheme: ColorScheme) -> Color {
        switch self {
        case .system: Self.pick(scheme, light: 0xE4E4E9, dark: 0x161618)
        case .blue: Self.pick(scheme, light: 0x1D3557, dark: 0x111F33)
        case .graphite: Self.pick(scheme, light: 0x3A3A3E, dark: 0x1E1E20)
        case .green: Self.pick(scheme, light: 0x1E4636, dark: 0x122B21)
        }
    }

    /// The active tab and the editor's top bar, so the two look like one piece.
    func barColor(_ scheme: ColorScheme) -> Color {
        switch self {
        case .system: Self.pick(scheme, light: 0xFFFFFF, dark: 0x2C2C2E)
        case .blue: Self.pick(scheme, light: 0x2D5A8E, dark: 0x1E3D63)
        case .graphite: Self.pick(scheme, light: 0x58585D, dark: 0x343437)
        case .green: Self.pick(scheme, light: 0x2E6A50, dark: 0x1F4A38)
        }
    }

    /// Text and icons on the strip and the bar.
    var primaryText: Color { isTinted ? .white : .primary }
    var secondaryText: Color { isTinted ? .white.opacity(0.65) : .secondary }

    private static func pick(_ scheme: ColorScheme, light: UInt32, dark: UInt32) -> Color {
        Color(UIColor(rgb: scheme == .dark ? dark : light))
    }
}

private extension UIColor {
    nonisolated convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
