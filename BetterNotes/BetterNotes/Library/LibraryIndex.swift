import Foundation

/// `.library.json`: favorites, recents and the sort choice (SPEC, "File format").
/// Notebooks are referenced by their **id**, not by path, so a notebook moved in the Files
/// app is still a favorite. An id that no longer exists is simply ignored by the UI.
nonisolated struct LibraryIndex: Codable, Equatable, Sendable {
    static let maxRecents = 10

    var favorites: [UUID] = []
    /// Newest first.
    var recents: [UUID] = []
    var sortKey: LibrarySortKey = .name
    var sortAscending = true

    init() {}

    // Every field is optional on disk, so a file written by an older or newer version (or
    // edited by hand) still loads and never costs the user their other settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorites = (try? container.decodeIfPresent([UUID].self, forKey: .favorites)) ?? []
        recents = (try? container.decodeIfPresent([UUID].self, forKey: .recents)) ?? []
        sortKey = (try? container.decodeIfPresent(LibrarySortKey.self, forKey: .sortKey)) ?? .name
        sortAscending = (try? container.decodeIfPresent(Bool.self, forKey: .sortAscending)) ?? true
    }

    func isFavorite(_ id: UUID) -> Bool { favorites.contains(id) }

    mutating func toggleFavorite(_ id: UUID) {
        if let index = favorites.firstIndex(of: id) {
            favorites.remove(at: index)
        } else {
            favorites.append(id)
        }
    }

    mutating func recordOpened(_ id: UUID) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    mutating func forget(_ id: UUID) {
        favorites.removeAll { $0 == id }
        recents.removeAll { $0 == id }
    }
}

nonisolated struct LibraryIndexStore: Sendable {
    let root: URL

    var fileURL: URL { root.appending(path: ".library.json") }

    /// A missing file is a fresh library. A file that cannot be read is copied to
    /// `.library.json.unreadable` (it is only a convenience file, but it may be fixable by
    /// hand) and the library starts with the defaults.
    func load() -> LibraryIndex {
        guard let data = try? Data(contentsOf: fileURL) else { return LibraryIndex() }
        do {
            return try JSONDecoder().decode(LibraryIndex.self, from: data)
        } catch {
            let aside = root.appending(path: ".library.json.unreadable")
            if !FileManager.default.fileExists(atPath: aside.path) {
                try? FileManager.default.copyItem(at: fileURL, to: aside)
            }
            return LibraryIndex()
        }
    }

    func save(_ index: LibraryIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: fileURL, options: .atomic)
    }

    /// Load, change, save, for one small edit.
    @discardableResult
    func update(_ change: (inout LibraryIndex) -> Void) throws -> LibraryIndex {
        var index = load()
        change(&index)
        try save(index)
        return index
    }
}
