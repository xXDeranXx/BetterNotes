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

/// A text box: plain text in the system font. Its width is chosen by the user; its height
/// follows the text (`TextBoxLayout.height`).
nonisolated struct TextObject: Equatable, Sendable {
    var text: String
    var fontSize: Double
    /// "#RRGGBB", like the pen colors.
    var colorHex: String

    static let defaultFontSize: Double = 16
}

// MARK: meta.json

/// Written by hand instead of letting Swift generate it, so the JSON stays flat and readable:
/// `{"id": …, "x": 40, "y": 60, "width": 200, "height": 120, "type": "image", "file": "….jpg"}`
/// (Swift's automatic coding of enums with values nests them in awkward `_0` keys).
nonisolated extension PageObject: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, type, file, text, fontSize, colorHex
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
            content = .text(TextObject(
                text: try container.decode(String.self, forKey: .text),
                fontSize: try container.decode(Double.self, forKey: .fontSize),
                colorHex: try container.decode(String.self, forKey: .colorHex)))
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
