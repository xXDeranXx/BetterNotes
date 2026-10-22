import Foundation

nonisolated enum LibraryError: LocalizedError, Equatable {
    case isOpen
    case outsideLibrary
    case moveIntoItself
    case notAFolder
    case notANotebook
    case notInTrash

    var errorDescription: String? {
        switch self {
        case .isOpen:
            "This notebook (or a notebook in this folder) is open in a window. Close it there first."
        case .outsideLibrary:
            "This item is not inside the library."
        case .moveIntoItself:
            "A folder cannot be moved into itself."
        case .notAFolder:
            "The destination is not a folder."
        case .notANotebook:
            "This item is not a notebook."
        case .notInTrash:
            "This item is not in the trash."
        }
    }
}

/// An item waiting in `.Trash`. Each trashed item lives in its own `.Trash/<uuid>/` folder
/// next to an `origin.json`, so names never clash and "Put Back" knows where it came from.
nonisolated struct TrashedItem: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The trashed folder or notebook itself.
    let url: URL
    let name: String
    let trashedAt: Date
    /// Path of the original parent folder relative to the library root ("" = the root).
    let originalParent: String
}

/// Everything that changes the library's folder structure. No code path in the app deletes
/// user files except `purge`/`emptyTrash` below, which only touch `.Trash` (SPEC, rule 4).
nonisolated struct LibraryOperations: Sendable {
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    let location: LibraryLocation
    let registry: OpenNotebookRegistry

    init(location: LibraryLocation = .documents, registry: OpenNotebookRegistry = .shared) {
        self.location = location
        self.registry = registry
    }

    private var root: URL { location.root }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: URL) throws -> URL {
        try requireInsideLibrary(parent)
        let url = Self.uniqueURL(in: parent, baseName: NotebookPackage.fileName(forTitle: name), pathExtension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    // MARK: Rename

    /// Renames a folder, or a notebook (its title in `meta.json` **and** its `.inkbook` name,
    /// so the Files app shows the same name). Returns the new location.
    @discardableResult
    func rename(_ item: URL, to newName: String) throws -> URL {
        try requireInsideLibrary(item)
        guard !registry.isOpen(at: item) else { throw LibraryError.isOpen }
        let isNotebook = item.pathExtension == NotebookPackage.fileExtension
        let parent = item.deletingLastPathComponent()
        let cleaned = NotebookPackage.fileName(forTitle: newName)

        if isNotebook {
            // Title first: if the move below fails, the title is merely ahead of the file
            // name, which is harmless.
            let package = NotebookPackage(url: item)
            try package.finishPendingCommit()
            var meta = try package.readMeta()
            meta.title = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cleaned : newName
            meta.updatedAt = .now
            try package.writeMeta(meta)
        }

        let currentName = isNotebook ? item.deletingPathExtension().lastPathComponent : item.lastPathComponent
        if currentName == cleaned { return item }
        let target = Self.uniqueURL(
            in: parent, baseName: cleaned, pathExtension: isNotebook ? NotebookPackage.fileExtension : nil)
        try FileManager.default.moveItem(at: item, to: target)
        return target
    }

    // MARK: Move

    /// Moves a folder or notebook into `destination` (a folder, or the library root). A name
    /// clash gets " 2" appended; nothing is ever overwritten.
    @discardableResult
    func move(_ item: URL, into destination: URL) throws -> URL {
        try requireInsideLibrary(item)
        try requireInsideLibrary(destination)
        guard !registry.isOpen(at: item) else { throw LibraryError.isOpen }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue, destination.pathExtension != NotebookPackage.fileExtension
        else { throw LibraryError.notAFolder }

        let itemPath = Self.path(item), destinationPath = Self.path(destination)
        if destinationPath == itemPath || destinationPath.hasPrefix(itemPath + "/") {
            throw LibraryError.moveIntoItself
        }
        if Self.path(item.deletingLastPathComponent()) == destinationPath { return item }  // already there

        let isNotebook = item.pathExtension == NotebookPackage.fileExtension
        let baseName = isNotebook ? item.deletingPathExtension().lastPathComponent : item.lastPathComponent
        let target = Self.uniqueURL(
            in: destination, baseName: baseName, pathExtension: isNotebook ? NotebookPackage.fileExtension : nil)
        try FileManager.default.moveItem(at: item, to: target)
        return target
    }

    // MARK: Duplicate

    /// Copies a notebook as "<title> copy" with a new id, today as creation date, and the
    /// same pages and ink. Built in a hidden staging folder and renamed into place, like a
    /// new notebook. Only what is saved on disk is copied (an open notebook's unsaved ink
    /// is not included).
    @discardableResult
    func duplicate(_ notebook: URL) throws -> URL {
        try requireInsideLibrary(notebook)
        guard notebook.pathExtension == NotebookPackage.fileExtension else { throw LibraryError.notANotebook }
        let fileManager = FileManager.default
        let parent = notebook.deletingLastPathComponent()
        let staging = parent.appending(path: ".\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: notebook, to: staging)
            let package = NotebookPackage(url: staging)
            try package.finishPendingCommit()
            var meta = try package.readMeta()
            meta.id = UUID()
            meta.title += " copy"
            meta.createdAt = .now
            meta.updatedAt = .now
            try package.writeMeta(meta)
            let target = Self.uniqueURL(
                in: parent, baseName: NotebookPackage.fileName(forTitle: meta.title),
                pathExtension: NotebookPackage.fileExtension)
            try fileManager.moveItem(at: staging, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: staging)  // only our own staging copy
            throw error
        }
    }

    // MARK: Trash

    private struct Origin: Codable {
        var originalParent: String
        var trashedAt: Date
    }

    /// Moves a folder or notebook into `.Trash`. The notebook's files are not touched.
    @discardableResult
    func trash(_ item: URL, now: Date = .now) throws -> TrashedItem {
        try requireInsideLibrary(item)
        guard !registry.isOpen(at: item) else { throw LibraryError.isOpen }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: location.trash, withIntermediateDirectories: true)

        let id = UUID()
        let slot = location.trash.appending(path: id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: slot, withIntermediateDirectories: false)
        let parentPath = Self.relativePath(of: item.deletingLastPathComponent(), from: root)
        do {
            try fileManager.moveItem(at: item, to: slot.appending(path: item.lastPathComponent))
            let origin = Origin(originalParent: parentPath, trashedAt: now)
            try Self.encoder.encode(origin).write(to: slot.appending(path: "origin.json"), options: .atomic)
        } catch {
            // Move failed or the note could not be written: the item is still where it was
            // (or in its slot; it is never lost). Remove the slot only if it is empty.
            try? fileManager.removeItem(at: slot.appending(path: "origin.json"))
            if (try? fileManager.contentsOfDirectory(atPath: slot.path))?.isEmpty == true {
                try? fileManager.removeItem(at: slot)
            }
            throw error
        }
        return TrashedItem(
            id: id, url: slot.appending(path: item.lastPathComponent), name: item.lastPathComponent,
            trashedAt: now, originalParent: parentPath)
    }

    func trashedItems() -> [TrashedItem] {
        let slots = (try? FileManager.default.contentsOfDirectory(
            at: location.trash, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return slots.compactMap { slot -> TrashedItem? in
            guard let id = UUID(uuidString: slot.lastPathComponent) else { return nil }
            let entries = ((try? FileManager.default.contentsOfDirectory(
                at: slot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { $0.lastPathComponent != "origin.json" }
            guard let item = entries.first else { return nil }
            let origin = (try? Data(contentsOf: slot.appending(path: "origin.json")))
                .flatMap { try? Self.decoder.decode(Origin.self, from: $0) }
            let fallbackDate = (try? slot.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .now
            return TrashedItem(
                id: id, url: item, name: item.lastPathComponent,
                trashedAt: origin?.trashedAt ?? fallbackDate, originalParent: origin?.originalParent ?? "")
        }
        .sorted { $0.trashedAt > $1.trashedAt }
    }

    /// Puts an item back in its original folder, or in the library root if that folder is
    /// gone. Returns the new location.
    @discardableResult
    func putBack(_ item: TrashedItem) throws -> URL {
        let fileManager = FileManager.default
        guard Self.path(item.url).hasPrefix(Self.path(location.trash) + "/"),
              fileManager.fileExists(atPath: item.url.path)
        else { throw LibraryError.notInTrash }

        var parent = item.originalParent.isEmpty
            ? root : root.appending(path: item.originalParent, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            parent = root
        }
        let isNotebook = item.url.pathExtension == NotebookPackage.fileExtension
        let baseName = isNotebook ? item.url.deletingPathExtension().lastPathComponent : item.url.lastPathComponent
        let target = Self.uniqueURL(
            in: parent, baseName: baseName, pathExtension: isNotebook ? NotebookPackage.fileExtension : nil)
        try fileManager.moveItem(at: item.url, to: target)
        try? fileManager.removeItem(at: item.url.deletingLastPathComponent())  // the now empty slot
        return target
    }

    /// Permanently removes trashed items older than 30 days. Returns how many were removed.
    @discardableResult
    func purgeExpired(now: Date = .now) -> Int {
        let expired = trashedItems().filter { now.timeIntervalSince($0.trashedAt) > Self.trashRetention }
        return expired.filter(purge).count
    }

    /// Permanently removes everything in the trash (the user asked for it).
    @discardableResult
    func emptyTrash() -> Int {
        trashedItems().filter(purge).count
    }

    @discardableResult
    func purge(_ item: TrashedItem) -> Bool {
        // Only ever a slot directly inside .Trash.
        let slot = item.url.deletingLastPathComponent()
        guard Self.path(slot.deletingLastPathComponent()) == Self.path(location.trash) else { return false }
        return (try? FileManager.default.removeItem(at: slot)) != nil
    }

    // MARK: Helpers

    private func requireInsideLibrary(_ url: URL) throws {
        let path = Self.path(url), rootPath = Self.path(root)
        let trashPath = Self.path(location.trash)
        guard path == rootPath || path.hasPrefix(rootPath + "/"),
              path != trashPath, !path.hasPrefix(trashPath + "/")
        else { throw LibraryError.outsideLibrary }
    }

    /// "Name.ext", or "Name 2.ext", "Name 3.ext", ... if that name is taken.
    static func uniqueURL(in parent: URL, baseName: String, pathExtension: String?) -> URL {
        func candidate(_ name: String) -> URL {
            let file = pathExtension.map { "\(name).\($0)" } ?? name
            return parent.appending(path: file, directoryHint: .isDirectory)
        }
        var url = candidate(baseName)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("\(baseName) \(number)")
            number += 1
        }
        return url
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let full = path(url), base = path(root)
        guard full.hasPrefix(base + "/") else { return "" }
        return String(full.dropFirst(base.count + 1))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
