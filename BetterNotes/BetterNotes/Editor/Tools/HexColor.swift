import UIKit

/// Colors typed or stored as "#RRGGBB". The library already stores cover colors this way
/// (`NotebookMeta.coverColor`), so pens use the same text format.
nonisolated enum HexColor {
    /// "#AABBCC" for "aabbcc", "#abc", "AABBCC" or " #AABBCC "; `nil` if it is not a color.
    static func normalized(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    /// The color for a hex text; `nil` if the text is not valid.
    static func color(_ text: String) -> UIColor? {
        guard let hex = normalized(text), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// "#RRGGBB" of a color (its alpha is dropped; pens get their opacity from the pen type).
    static func hex(of color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Resolve in the light appearance: pages are white (see `PageRenderer`).
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            if !color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a) {
                var white: CGFloat = 0
                color.getWhite(&white, alpha: &a)
                r = white; g = white; b = white
            }
        }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
