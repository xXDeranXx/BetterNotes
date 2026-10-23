import CoreGraphics
import Foundation

/// An image or a text box on a page (SPEC, "Objects on pages"). Objects lie below the ink and
/// belong to a page id, like ink: they are stored in that page's entry in `meta.json`.
///
/// `frame` is in page coordinates, the same as ink: points, origin at the top-left of the
/// unrotated page, y pointing down (see `PageGeometry`). A rotated page turns its objects with it.
nonisolated struct PageObject: Equatable, Identifiable, Sendable {
    var id: UUID
    var frame: CGRect
    var content: ObjectContent

    init(id: UUID = UUID(), frame: CGRect, content: ObjectContent) {
        self.id = id
        self.frame = frame
        self.content = content
    }

    /// The file in the notebook's `objects/` folder, for an image; nil for a text box.
    var imageFile: String? {
        if case .image(let image) = content { image.file } else { nil }
    }
}

nonisolated enum ObjectContent: Equatable, Sendable {
    case image(ImageObject)
    case text(TextObject)
}

/// An inserted picture. The file is never changed after it was written, so several objects
/// (a duplicated page, an undone delete) can share it.
nonisolated struct ImageObject: Equatable, Sendable {
    /// Name of the file in `objects/`, for example "6F1C….jpg".
    var file: String
}

/// A text box: text in one font family, size and color, with bold and italic words. Its width
/// is chosen by the user; its height follows the text (`TextBoxLayout.height`).
///
/// `text` stays a plain string (search, copy and export read it); bold and italic are kept
/// apart in `styles`, like a list of `<b>`/`<i>` ranges over the string.
nonisolated struct TextObject: Equatable, Sendable {
    var text: String
    var fontSize: Double
    /// "#RRGGBB", like the pen colors.
    var colorHex: String
    var font: TextFont = .system
    /// The bold and italic parts of `text`, sorted, not overlapping, never empty or plain.
    var styles: [TextStyleRun] = []

    static let defaultFontSize: Double = 16

    /// The length `styles` count in: UTF-16 units, like `NSString` and `NSRange` (an emoji
    /// counts 2 here and 1 in `String.count`).
    var utf16Length: Int { (text as NSString).length }

    /// Bold and italic of every UTF-16 unit, from `styles`.
    func styleFlags() -> [TextStyleRun.Flags] {
        var flags = [TextStyleRun.Flags](repeating: [], count: utf16Length)
        for run in styles {
            let start = max(0, min(run.start, flags.count))
            let end = max(start, min(run.start + run.length, flags.count))
            for index in start..<end { flags[index].formUnion(run.flags) }
        }
        return flags
    }

    /// True when every character is bold (or italic), and there is text.
    func isEverywhere(_ flag: TextStyleRun.Flags) -> Bool {
        let flags = styleFlags()
        return !flags.isEmpty && flags.allSatisfy { $0.contains(flag) }
    }

    /// Makes the whole text bold (or italic), or not, keeping the other style as it is.
    mutating func set(_ flag: TextStyleRun.Flags, everywhere on: Bool) {
        styles = TextStyleRun.runs(from: styleFlags().map { on ? $0.union(flag) : $0.subtracting(flag) })
    }

    /// Repairs `styles` read from a file: clamped to the text, sorted, merged.
    mutating func normalizeStyles() {
        styles = TextStyleRun.runs(from: styleFlags())
    }
}

/// The font families a text box can use. The raw value is what `meta.json` stores; an unknown
/// value (written by a newer app) reads as `.system`.
nonisolated enum TextFont: String, CaseIterable, Sendable {
    case system, serif, rounded, monospaced, georgia, noteworthy

    var displayName: String {
        switch self {
        case .system: "System"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .monospaced: "Monospaced"
        case .georgia: "Georgia"
        case .noteworthy: "Noteworthy"
        }
    }
}

/// A bold and/or italic part of a text box's text, in UTF-16 units (see `TextObject.utf16Length`).
nonisolated struct TextStyleRun: Equatable, Codable, Sendable {
    var start: Int
    var length: Int
    var bold: Bool
    var italic: Bool

    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let bold = Flags(rawValue: 1)
        static let italic = Flags(rawValue: 2)
    }

    var flags: Flags {
        var flags: Flags = []
        if bold { flags.insert(.bold) }
        if italic { flags.insert(.italic) }
        return flags
    }

    /// The runs for per-unit flags: one run per stretch of equal, non-plain flags.
    static func runs(from flags: [Flags]) -> [TextStyleRun] {
        var runs: [TextStyleRun] = []
        var index = 0
        while index < flags.count {
            let current = flags[index]
            var end = index + 1
            while end < flags.count, flags[end] == current { end += 1 }
            if !current.isEmpty {
                runs.append(TextStyleRun(
                    start: index, length: end - index, bold: current.contains(.bold), italic: current.contains(.italic)))
            }
            index = end
        }
        return runs
    }
}

// MARK: meta.json

/// Written by hand instead of letting Swift generate it, so the JSON stays flat and readable:
/// `{"id": …, "x": 40, "y": 60, "width": 200, "height": 120, "type": "image", "file": "….jpg"}`
/// (Swift's automatic coding of enums with values nests them in awkward `_0` keys).
nonisolated extension PageObject: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, type, file, text, fontSize, colorHex, font, styles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = CGRect(
            x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y),
            width: try container.decode(Double.self, forKey: .width),
            height: try container.decode(Double.self, forKey: .height))
        switch try container.decode(String.self, forKey: .type) {
        case "image":
            content = .image(ImageObject(file: try container.decode(String.self, forKey: .file)))
        case "text":
            // `font` and `styles` came with format version 3; older text boxes have neither.
            var text = TextObject(
                text: try container.decode(String.self, forKey: .text),
                fontSize: try container.decode(Double.self, forKey: .fontSize),
                colorHex: try container.decode(String.self, forKey: .colorHex),
                font: (try container.decodeIfPresent(String.self, forKey: .font)).flatMap(TextFont.init(rawValue:)) ?? .system,
                styles: try container.decodeIfPresent([TextStyleRun].self, forKey: .styles) ?? [])
            text.normalizeStyles()
            content = .text(text)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown object type \"\(other)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Double(frame.minX), forKey: .x)
        try container.encode(Double(frame.minY), forKey: .y)
        try container.encode(Double(frame.width), forKey: .width)
        try container.encode(Double(frame.height), forKey: .height)
        switch content {
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image.file, forKey: .file)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text.text, forKey: .text)
            try container.encode(text.fontSize, forKey: .fontSize)
            try container.encode(text.colorHex, forKey: .colorHex)
            try container.encode(text.font.rawValue, forKey: .font)
            if !text.styles.isEmpty { try container.encode(text.styles, forKey: .styles) }
        }
    }

    /// A short text that changes whenever the objects would look different. Thumbnail files
    /// on disk carry it in their name, so a picture made before an object changed is not reused.
    /// (Swift's `hashValue` changes on every launch, so it cannot be used for files.)
    static func fingerprint(of objects: [PageObject]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(objects)) ?? Data()
        // FNV-1a: a tiny, well-known hash function.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The same object with a new id, for copies of a page (ids stay unique in a notebook).
    func withNewID() -> PageObject {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
