import UIKit

/// How a text box looks: one place for the fonts, the padding and the line layout, used by the
/// text box on screen, the text view while typing, and `PageRenderer` (thumbnails, export), so an
/// export matches the screen.
///
/// The text is an `NSAttributedString`: a string plus attributes (font, color) for its
/// characters, a little like a `<span style="…">` in HTML. UIKit can measure and draw it.
nonisolated enum TextBoxLayout {
    /// Space between the box's edge and its text, in page points.
    static let padding: CGFloat = 4
    /// A box is never narrower than this, so it stays easy to hit.
    static let minimumWidth: CGFloat = 40
    /// The width of a new text box.
    static let defaultWidth: CGFloat = 240
    /// A pasted text is at most this wide (it wraps beyond).
    static let maximumPastedWidth: CGFloat = 360

    /// The font for a family, size and style. A face the family does not have (Noteworthy has
    /// no italic) falls back to the closest one it has, so the text still shows.
    static func font(_ family: TextFont, size: Double, bold: Bool = false, italic: Bool = false) -> UIFont {
        let size = CGFloat(size)
        let base: UIFont
        switch family {
        case .system: base = .systemFont(ofSize: size)
        case .serif: base = designed(.serif, size: size)
        case .rounded: base = designed(.rounded, size: size)
        case .monospaced: base = designed(.monospaced, size: size)
        case .georgia: base = UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .noteworthy: base = UIFont(name: "Noteworthy-Light", size: size) ?? .systemFont(ofSize: size)
        }
        var wanted: UIFontDescriptor.SymbolicTraits = []
        if bold { wanted.insert(.traitBold) }
        if italic { wanted.insert(.traitItalic) }
        // Both, then each alone (a family may have bold but no italic).
        for traits in [wanted, wanted.intersection(.traitBold), wanted.intersection(.traitItalic)] where !traits.isEmpty {
            let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
            if let descriptor { return UIFont(descriptor: descriptor, size: size) }
        }
        return base
    }

    /// The system font in one of its designs (New York for serif, SF Rounded, SF Mono).
    private static func designed(_ design: UIFontDescriptor.SystemDesign, size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size)
        guard let descriptor = system.fontDescriptor.withDesign(design) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func color(of text: TextObject) -> UIColor {
        HexColor.color(text.colorHex) ?? .black
    }

    /// Font and color for characters of this box with this style.
    static func attributes(for text: TextObject, bold: Bool = false, italic: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: font(text.font, size: text.fontSize, bold: bold, italic: italic), .foregroundColor: color(of: text)]
    }

    static func attributedString(for text: TextObject) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text.text, attributes: attributes(for: text))
        let length = string.length
        for run in text.styles {
            let range = NSRange(location: run.start, length: run.length)
            guard range.location >= 0, NSMaxRange(range) <= length else { continue }
            string.addAttribute(.font, value: font(text.font, size: text.fontSize, bold: run.bold, italic: run.italic), range: range)
        }
        return string
    }

    /// The bold and italic parts of typed (or pasted) text, read from its fonts. Everything else
    /// (another font, size or color pasted in) is ignored: the box's own settings apply.
    static func styles(from attributed: NSAttributedString) -> [TextStyleRun] {
        var flags = [TextStyleRun.Flags](repeating: [], count: attributed.length)
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            var style: TextStyleRun.Flags = []
            if traits.contains(.traitBold) { style.insert(.bold) }
            if traits.contains(.traitItalic) { style.insert(.italic) }
            for index in range.location..<NSMaxRange(range) { flags[index] = style }
        }
        return TextStyleRun.runs(from: flags)
    }

    /// The box's height for its text at `width`: the wrapped text plus padding, at least one line.
    static func height(of text: TextObject, width: CGFloat) -> CGFloat {
        let inner = max(1, width - 2 * padding)
        // An empty last line (text ending in a newline) is not measured by itself; add a space.
        var measured = text
        if text.text.isEmpty || text.text.hasSuffix("\n") { measured.text += " " }
        let bounds = attributedString(for: measured).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return (bounds.height + 2 * padding).rounded(.up)
    }

    /// The width a pasted text gets: its longest line, but not wider than `maximumPastedWidth`
    /// or the room on the page.
    static func pastedWidth(of text: TextObject, pageWidth: CGFloat) -> CGFloat {
        let natural = attributedString(for: text).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).width.rounded(.up) + 2 * padding + 2  // a little slack, so the longest line does not wrap
        return max(minimumWidth, min(natural, maximumPastedWidth, pageWidth))
    }

    /// Draws the text into the current UIKit drawing context (`UIGraphicsPushContext`), whose
    /// units are page points with y pointing down.
    static func draw(_ text: TextObject, in frame: CGRect) {
        attributedString(for: text).draw(
            with: frame.insetBy(dx: padding, dy: padding),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
