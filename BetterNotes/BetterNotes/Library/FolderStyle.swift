import Foundation

/// How a folder looks in the library: a symbol on the folder and a color. Stored in a hidden
/// `.folder.json` inside the folder itself, so the look travels with the folder when it is
/// moved or renamed (also in the Files app) and is part of every backup. A folder without
/// the file, or with a file that cannot be read, just looks default.
nonisolated struct FolderStyle: Codable, Equatable, Sendable {
    static let defaultColor = "#3A8DFF"
    static let fileName = ".folder.json"

    /// An SF Symbol name, or `nil` for a plain folder.
    var symbol: String?
    /// "#RRGGBB".
    var color: String

    init(symbol: String? = nil, color: String = FolderStyle.defaultColor) {
        self.symbol = symbol
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? nil
        color = (try? container.decodeIfPresent(String.self, forKey: .color)) ?? Self.defaultColor
    }

    static let `default` = FolderStyle()

    static func load(from folder: URL) -> FolderStyle {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)),
              let style = try? JSONDecoder().decode(FolderStyle.self, from: data)
        else { return .default }
        return style
    }

    /// A default style removes the file again, so plain folders stay plain.
    func save(to folder: URL) throws {
        let file = folder.appending(path: Self.fileName)
        if self == .default {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }  // our own small settings file
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
