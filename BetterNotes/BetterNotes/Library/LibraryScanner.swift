import Foundation

/// What the library shows for one notebook. Read from `meta.json` only, so scanning a
/// folder never opens a PDF.
nonisolated struct NotebookSummary: Identifiable, Equatable, Sendable {
    let url: URL
    /// `nil` if `meta.json` could not be read; the notebook is then listed with `problem`.
    let notebookID: UUID?
    var title: String
    var coverColor: String
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var problem: String?

    var id: URL { url }
}

nonisolated struct FolderSummary: Identifiable, Equatable, Sendable {
    let url: URL
    var name: String { url.lastPathComponent }
    var id: URL { url }
}

nonisolated struct FolderContents: Equatable, Sendable {
    var folders: [FolderSummary]
    var notebooks: [NotebookSummary]
}

nonisolated enum LibrarySortKey: String, Codable, CaseIterable, Sendable {
    case name, modified, created
}

nonisolated enum LibraryScanner {
    /// The folders and notebooks directly inside `folder`. Hidden items (`.Trash`,
    /// `.library.json`, staging folders of an interrupted create) are skipped. One notebook
    /// with a damaged `meta.json` is listed with a `problem` instead of hiding the rest.
    static func contents(of folder: URL) -> FolderContents {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var folders: [FolderSummary] = []
        var notebooks: [NotebookSummary] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if url.pathExtension == NotebookPackage.fileExtension {
                notebooks.append(summary(of: url))
            } else {
                folders.append(FolderSummary(url: url))
            }
        }
        return FolderContents(folders: folders, notebooks: notebooks)
    }

    /// Every notebook below `root`, in all nested folders (for search, favorites, recents).
    static func allNotebooks(under root: URL) -> [NotebookSummary] {
        let here = contents(of: root)
        return here.notebooks + here.folders.flatMap { allNotebooks(under: $0.url) }
    }

    /// Every folder below `root` (for the "Move to" picker and folder search).
    static func allFolders(under root: URL) -> [FolderSummary] {
        let here = contents(of: root).folders
        return here + here.flatMap { allFolders(under: $0.url) }
    }

    static func summary(of url: URL) -> NotebookSummary {
        let package = NotebookPackage(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        do {
            // A crash between the two page-operation files is repaired by the next open;
            // reading the pair as it is would show a stale page count until then.
            try package.finishPendingCommit()
            let meta = try package.readMeta()
            return NotebookSummary(
                url: url, notebookID: meta.id, title: meta.title, coverColor: meta.coverColor,
                createdAt: meta.createdAt, updatedAt: meta.updatedAt, pageCount: meta.pages.count,
                problem: nil)
        } catch {
            return NotebookSummary(
                url: url, notebookID: nil, title: fallbackTitle, coverColor: "#8E8E93",
                createdAt: .distantPast, updatedAt: .distantPast, pageCount: 0,
                problem: error.localizedDescription)
        }
    }

    // MARK: Sorting and search

    /// Folders always sort by name; the choice only applies to notebooks.
    static func sorted(_ folders: [FolderSummary]) -> [FolderSummary] {
        folders.sorted { compare($0.name, $1.name) }
    }

    static func sorted(_ notebooks: [NotebookSummary], by key: LibrarySortKey, ascending: Bool) -> [NotebookSummary] {
        notebooks.sorted { a, b in
            let result: ComparisonResult
            switch key {
            case .name: result = a.title.localizedStandardCompare(b.title)
            case .modified: result = a.updatedAt.compare(b.updatedAt)
            case .created: result = a.createdAt.compare(b.createdAt)
            }
            if result == .orderedSame {  // keep the order stable when the key ties
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            return (result == .orderedAscending) == ascending
        }
    }

    private static func compare(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Notebooks and folders whose title contains `query`, ignoring case and accents.
    static func search(_ query: String, under root: URL) -> FolderContents {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return FolderContents(folders: [], notebooks: []) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return FolderContents(
            folders: allFolders(under: root).filter { $0.name.range(of: trimmed, options: options) != nil },
            notebooks: allNotebooks(under: root).filter { $0.title.range(of: trimmed, options: options) != nil })
    }
}
