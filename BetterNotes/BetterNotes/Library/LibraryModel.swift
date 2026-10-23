import Foundation
import Observation

enum LibrarySection: Hashable {
    case documents, favorites, recents, trash
}

/// The state of one window's library screen: where the user is, what is there, and the
/// actions on it. Like a React store per window: the view reads it and calls its methods.
/// Scanning and file work run in the background (the file layer is `nonisolated`), and
/// results come back to the main thread.
@Observable
final class LibraryModel {
    static let coverColors = ["#4F6BED", "#E5484D", "#F5A524", "#30A46C", "#8E4EC6", "#0EA5A5", "#E93D82", "#6B7280"]

    @ObservationIgnored let location: LibraryLocation
    @ObservationIgnored let operations: LibraryOperations
    @ObservationIgnored let indexStore: LibraryIndexStore
    /// This window's tabs: notebooks in background tabs follow a rename or move, and close
    /// when trashed (tabs step 4). Without it (tests), anything open is refused.
    @ObservationIgnored weak var tabHost: WindowSession?

    var section: LibrarySection = .documents
    /// The folder shown in `.documents`; always inside the library root.
    private(set) var folder: URL
    var searchText = ""
    var errorMessage: String?

    /// Selection mode: tiles toggle a checkmark instead of opening, and the toolbar offers
    /// Move and Delete for everything selected.
    private(set) var isSelecting = false
    private(set) var selection: Set<URL> = []

    private(set) var contents = FolderContents(folders: [], notebooks: [])
    private(set) var allNotebooks: [NotebookSummary] = []
    private(set) var allFolders: [FolderSummary] = []
    private(set) var trashed: [TrashedItem] = []
    private(set) var index = LibraryIndex()
    private(set) var hasLoaded = false

    init(location: LibraryLocation = .documents, registry: OpenNotebookRegistry = .shared) {
        self.location = location
        operations = LibraryOperations(location: location, registry: registry)
        indexStore = LibraryIndexStore(root: location.root)
        folder = location.root
    }

    // MARK: What is shown

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var title: String {
        switch section {
        case .documents: isAtRoot ? "Documents" : folder.lastPathComponent
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .trash: "Trash"
        }
    }

    var isAtRoot: Bool { Self.samePlace(folder, location.root) }

    /// Root first, then each folder down to the current one.
    var breadcrumbs: [URL] {
        var chain: [URL] = []
        var current = folder
        while !Self.samePlace(current, location.root), current.pathComponents.count > location.root.pathComponents.count {
            chain.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        return [location.root] + chain
    }

    /// Folders and notebooks for the grid, depending on section and search.
    var shownFolders: [FolderSummary] {
        if isSearching { return LibraryScanner.sorted(allFolders.filter { matches($0.name) }) }
        return section == .documents ? LibraryScanner.sorted(contents.folders) : []
    }

    var shownNotebooks: [NotebookSummary] {
        let sorted = { (list: [NotebookSummary]) in
            LibraryScanner.sorted(list, by: self.index.sortKey, ascending: self.index.sortAscending)
        }
        if isSearching { return sorted(allNotebooks.filter { matches($0.title) }) }
        switch section {
        case .documents: return sorted(contents.notebooks)
        case .favorites: return sorted(allNotebooks.filter { $0.notebookID.map(index.isFavorite) ?? false })
        case .recents:
            // Newest opened first; an id whose notebook is gone is skipped.
            let byID = Dictionary(allNotebooks.compactMap { n in n.notebookID.map { ($0, n) } },
                                  uniquingKeysWith: { first, _ in first })
            return index.recents.compactMap { byID[$0] }
        case .trash: return []
        }
    }

    private func matches(_ text: String) -> Bool {
        text.range(of: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                   options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func isFavorite(_ notebook: NotebookSummary) -> Bool {
        notebook.notebookID.map(index.isFavorite) ?? false
    }

    // MARK: Loading

    private struct Snapshot: Sendable {
        var folder: URL
        var contents: FolderContents
        var allNotebooks: [NotebookSummary]
        var allFolders: [FolderSummary]
        var trashed: [TrashedItem]
        var index: LibraryIndex
    }

    /// Rescans the disk. Called on appearance, after every change, and when the app returns
    /// to the foreground (files may have moved in the Files app meanwhile).
    func reload() async {
        let location = location, operations = operations, store = indexStore
        let wantsAll = section != .documents || isSearching
        let wantsTrash = section == .trash
        var folder = self.folder
        let snapshot = await Task.detached { () -> Snapshot in
            // A folder that was moved or deleted outside the app: go back to the root.
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                folder = location.root
            }
            return Snapshot(
                folder: folder, contents: LibraryScanner.contents(of: folder),
                allNotebooks: wantsAll ? LibraryScanner.allNotebooks(under: location.root) : [],
                allFolders: wantsAll ? LibraryScanner.allFolders(under: location.root) : [],
                trashed: wantsTrash ? operations.trashedItems() : [], index: store.load())
        }.value
        self.folder = snapshot.folder
        contents = snapshot.contents
        allNotebooks = snapshot.allNotebooks
        allFolders = snapshot.allFolders
        trashed = snapshot.trashed
        index = snapshot.index
        hasLoaded = true
    }

    /// Once per launch: drop trash older than 30 days.
    func purgeExpiredTrash() async {
        let operations = operations
        await Task.detached { operations.purgeExpired() }.value
    }

    func show(folder url: URL) async {
        folder = url
        searchText = ""
        endSelecting()
        await reload()
    }

    func select(_ section: LibrarySection) async {
        self.section = section
        endSelecting()
        await reload()
    }

    // MARK: Selection

    func startSelecting() { isSelecting = true; selection = [] }

    func endSelecting() { isSelecting = false; selection = [] }

    func toggleSelection(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    /// Everything currently shown (folders and notebooks).
    var selectableURLs: [URL] { shownFolders.map(\.url) + shownNotebooks.map(\.url) }

    var allSelected: Bool { !selectableURLs.isEmpty && selection.count == selectableURLs.count }

    func selectAll() { selection = Set(selectableURLs) }

    func setLayout(_ layout: LibraryLayout) { updateIndex { $0.layout = layout } }

    /// Runs `work` for each item, one after another. Items that fail (for example a notebook
    /// that is open in another window) are listed in one message; the others still go through.
    private func performEach(_ urls: [URL], trashes: Bool = false, _ work: @escaping @Sendable (URL) throws -> URL) async {
        var failures: [String] = []
        for url in urls {
            if let error = await changeFiles(at: url, trashes: trashes, { try work(url) }) {
                failures.append("\(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        endSelecting()
        await reload()
    }

    func moveSelection(into destination: URL) async {
        let operations = operations
        await performEach(Array(selection)) { try operations.move($0, into: destination) }
    }

    func trashSelection() async {
        let operations = operations
        await performEach(Array(selection), trashes: true) { _ = try operations.trash($0); return $0 }
    }

    /// File work on something that may be in a background tab of this window: the tabs are
    /// taken off the notebook first, then follow it to the place `work` returns (or close when
    /// it was trashed, or stay where they were when `work` failed). Returns the error, if any.
    private func changeFiles(at url: URL, trashes: Bool = false, _ work: @escaping @Sendable () throws -> URL) async -> Error? {
        let detached: WindowSession.DetachedTabs
        do {
            detached = try await tabHost?.detachTabs(under: url) ?? .none
        } catch {
            return error
        }
        do {
            let newURL = try await Task.detached { try work() }.value
            tabHost?.reattach(detached, movedFrom: url, to: trashes ? nil : newURL)
            return nil
        } catch {
            tabHost?.reattach(detached, movedFrom: url, to: url)
            return error
        }
    }

    /// `changeFiles` for one item, then rescans; a failure becomes `errorMessage`.
    private func performChange(at url: URL, trashes: Bool = false, _ work: @escaping @Sendable () throws -> URL) async {
        if let error = await changeFiles(at: url, trashes: trashes, work) { errorMessage = error.localizedDescription }
        await reload()
    }

    // MARK: Actions

    /// Runs file work in the background, then rescans. A failure becomes `errorMessage`.
    private func perform(_ work: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached { try work() }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    func createFolder(named name: String) async {
        let operations = operations, parent = folder
        await perform { try operations.createFolder(named: name, in: parent) }
    }

    func createNotebook(title: String, template: PageTemplate, size: PageSize, coverColor: String) async -> NotebookPackage? {
        let parent = folder
        do {
            let package = try await Task.detached {
                try NotebookPackage.create(in: parent, title: title, template: template, size: size, coverColor: coverColor)
            }.value
            await reload()
            return package
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func createWhiteboard(title: String, background: BoardBackground, coverColor: String) async -> NotebookPackage? {
        let parent = folder
        do {
            let package = try await Task.detached {
                try NotebookPackage.createWhiteboard(in: parent, title: title, background: background, coverColor: coverColor)
            }.value
            await reload()
            return package
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A new notebook in the folder on screen from scanned pages, titled "Scan <date>".
    func createNotebookFromScan(_ jpegs: [Data]) async -> NotebookPackage? {
        let parent = folder, title = ScanPages.notebookTitle()
        do {
            let package = try await Task.detached {
                try NotebookPackage.importScan(jpegs: jpegs, in: parent, title: title, coverColor: PDFImporter.coverColor)
            }.value
            await reload()
            return package
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ url: URL, to name: String) async {
        let operations = operations
        await performChange(at: url) { try operations.rename(url, to: name) }
    }

    func move(_ url: URL, into destination: URL) async {
        let operations = operations
        await performChange(at: url) { try operations.move(url, into: destination) }
    }

    func duplicate(_ url: URL) async {
        let operations = operations
        await perform { try operations.duplicate(url) }
    }

    func setFolderStyle(_ style: FolderStyle, for url: URL) async {
        let operations = operations
        await perform { try operations.setFolderStyle(style, for: url) }
    }

    /// Symbols offered for folders (SF Symbols).
    static let folderSymbols = [
        "book.closed", "books.vertical", "graduationcap", "building.columns", "pencil.and.ruler", "function",
        "atom", "flask", "globe.europe.africa", "laptopcomputer", "chart.bar", "music.note",
        "paintpalette", "heart", "star", "briefcase", "house", "person.2", "leaf", "flag",
        "lightbulb", "calendar", "doc.text", "camera",
    ]

    func setCoverColor(_ color: String, for url: URL) async {
        let operations = operations
        await performChange(at: url) { try operations.setCoverColor(color, for: url); return url }
    }

    func trash(_ url: URL) async {
        let operations = operations
        await performChange(at: url, trashes: true) { _ = try operations.trash(url); return url }
    }

    func putBack(_ item: TrashedItem) async {
        let operations = operations
        await perform { try operations.putBack(item) }
    }

    func deleteForever(_ item: TrashedItem) async {
        let operations = operations
        await perform { operations.purge(item) }
    }

    func emptyTrash() async {
        let operations = operations
        await perform { operations.emptyTrash() }
    }

    func toggleFavorite(_ notebook: NotebookSummary) async {
        guard let id = notebook.notebookID else { return }
        updateIndex { $0.toggleFavorite(id) }
        await reload()
    }

    func setSort(_ key: LibrarySortKey, ascending: Bool) {
        updateIndex { $0.sortKey = key; $0.sortAscending = ascending }
    }

    func recordBackup() {
        updateIndex { $0.lastBackup = .now }
    }

    /// Copies a picked folder (an unzipped backup) or notebook into the folder on screen.
    /// Returns a short message for the user, or `nil` if it failed (`errorMessage` is set).
    func importFolder(from source: URL) async -> String? {
        let parent = folder
        do {
            let result = try await Task.detached { () -> (url: URL, notebookCount: Int) in
                // The picker's URL is only readable between these two calls.
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                return try LibraryBackup.importFolder(from: source, into: parent)
            }.value
            await reload()
            return "Imported \(result.notebookCount) \(result.notebookCount == 1 ? "notebook" : "notebooks") as \"\(result.url.deletingPathExtension().lastPathComponent)\"."
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func recordOpened(_ notebook: NotebookSummary) {
        guard let id = notebook.notebookID else { return }
        updateIndex { $0.recordOpened(id) }
    }

    /// Changes `.library.json`. The screen updates at once; a failed write only costs the
    /// remembered choice, so it is reported but nothing else suffers.
    private func updateIndex(_ change: (inout LibraryIndex) -> Void) {
        change(&index)
        do { try indexStore.save(index) } catch { errorMessage = "Could not save library settings: \(error.localizedDescription)" }
    }

    // MARK: Drag and drop

    private static let dragPrefix = "inkbook-item:"

    /// What is dragged: the item's path inside the library, as text with a prefix so other
    /// text dropped on a folder is ignored.
    func dragPayload(for url: URL) -> String {
        let root = location.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return Self.dragPrefix + (path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path)
    }

    func dragged(from payload: String) -> URL? {
        guard payload.hasPrefix(Self.dragPrefix) else { return nil }
        let relative = String(payload.dropFirst(Self.dragPrefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        return location.root.appending(path: relative)
    }

    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
