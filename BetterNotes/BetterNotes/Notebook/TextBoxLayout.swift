import UIKit

/// How a text box looks: one place for the font, the padding and the line layout, used by the
/// text box on screen and by `PageRenderer` (thumbnails, export), so an export matches the screen.
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

    static func font(size: Double) -> UIFont {
        UIFont.systemFont(ofSize: CGFloat(size))
    }

    static func attributes(for text: TextObject) -> [NSAttributedString.Key: Any] {
        [.font: font(size: text.fontSize), .foregroundColor: HexColor.color(text.colorHex) ?? .black]
    }

    static func attributedString(for text: TextObject) -> NSAttributedString {
        NSAttributedString(string: text.text, attributes: attributes(for: text))
    }

    /// The box's height for its text at `width`: the wrapped text plus padding, at least one line.
    static func height(of text: TextObject, width: CGFloat) -> CGFloat {
        let inner = max(1, width - 2 * padding)
        // An empty last line (text ending in a newline) is not measured by itself; add a space.
        let measured = text.text.isEmpty || text.text.hasSuffix("\n") ? text.text + " " : text.text
        let bounds = NSAttributedString(string: measured, attributes: attributes(for: text)).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return (bounds.height + 2 * padding).rounded(.up)
    }

    /// Draws the text into the current UIKit drawing context (`UIGraphicsPushContext`), whose
    /// units are page points with y pointing down.
    static func draw(_ text: TextObject, in frame: CGRect) {
        attributedString(for: text).draw(
            with: frame.insetBy(dx: padding, dy: padding),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
