import Foundation
import Observation
import SwiftUI

/// Everything that belongs to one window (SPEC, architecture decision 5): its tabs, which one
/// is shown, and with them the notebooks' models and undo histories. Each window creates its
/// own session; nothing is shared through a global, so two windows never interfere.
///
/// Compare with React: this is like a store created per component instance with
/// `useRef`, not a module-level singleton.
///
/// Tabs (see `docs/DECISIONS.md`, "Tabs, design"): only the active tab has an editor. The
/// `loadedTabLimit` most recently used tabs keep their model (and undo); older ones are saved
/// and released. With no active tab the window shows the library, and the tabs stay.
@Observable
final class WindowSession {
    /// The active tab plus the most recent background ones that keep their model.
    static let loadedTabLimit = 5  // 10 tabs measured 115 MB on the iPad (2026-10-23)

    private(set) var tabs: [NotebookTab] = []
    /// nil while the library is shown.
    private(set) var activeTabID: UUID?

    var activeTab: NotebookTab? { tabs.first { $0.id == activeTabID } }
    /// The notebook on screen, if any.
    var notebook: Notebook? { activeTab?.notebook }

    /// This window's id in the registry.
    @ObservationIgnored let windowID = UUID()
    /// The pens and tools, shared by all tabs of the window, so switching keeps the tool.
    @ObservationIgnored let tools = ToolController()
    /// Set by the shown editor: puts typed text into the model and stores the scroll position
    /// in the editor's own tab. Called before the shown tab changes in any way (another tab,
    /// the library, closing), while the editor still exists.
    @ObservationIgnored var beforeLeavingTab: (() -> Void)?
    @ObservationIgnored let registry: OpenNotebookRegistry
    @ObservationIgnored private var useCounter = 0
    /// The saves that release old tabs run one after another; tests wait for this.
    @ObservationIgnored private(set) var releaseTask: Task<Void, Never>?

    init(registry: OpenNotebookRegistry = .shared) {
        self.registry = registry
    }

    /// A window that goes away (the user swipes it away) lets go of all its notebooks. Their
    /// changes were saved when the app left the foreground.
    isolated deinit {
        registry.releaseAll(ownedBy: windowID)
    }

    // MARK: Tabs

    /// Opens a notebook in a new tab and shows it. A notebook that already has a tab in this
    /// window shows that tab instead; one that is open in another window is refused.
    func open(_ package: NotebookPackage) throws {
        if let tab = tab(for: package.url) {
            try select(tab.id)
            return
        }
        let id = UUID()
        guard registry.claim(package.url, by: NotebookOwner(window: windowID, tab: id)) else {
            throw NotebookError.alreadyOpen
        }
        do {
            let tab = NotebookTab(id: id, notebook: try Notebook.open(package))
            tabs.append(tab)
            activate(tab)
        } catch {
            registry.release(package.url)
            throw error
        }
    }

    /// This window's tab for a notebook, found through the registry (so another path to the
    /// same folder finds it too).
    func tab(for url: URL) -> NotebookTab? {
        guard let owner = registry.owner(of: url), owner.window == windowID else { return nil }
        return tabs.first { $0.id == owner.tab }
    }

    /// Shows a tab, loading its notebook again if it was released. A notebook that cannot be
    /// loaded any more (deleted or broken in the Files app) loses its tab, and the error says why.
    func select(_ id: UUID) throws {
        // A detached tab's notebook is being moved by the library right now.
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isDetached else { return }
        do {
            _ = try tab.load()
        } catch {
            remove(tab)
            throw error
        }
        activate(tab)
    }

    /// Home: the library, with all tabs kept.
    func showLibrary() {
        leaveCurrent()
        activeTabID = nil
    }

    /// Saves and closes a tab. If saving fails the tab stays (its `saveError` explains why),
    /// because closing would throw away the unsaved ink. Closing the shown tab shows its
    /// neighbour, or the library after the last one. `false` if the tab stayed.
    @discardableResult
    func closeTab(_ id: UUID) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return true }
        guard !tab.isDetached else { return false }  // the library is moving its notebook
        if id == activeTabID { beforeLeavingTab?() }  // typed text goes into the closing save
        if let notebook = tab.notebook {
            await notebook.saveChanges()
            guard !notebook.hasUnsavedChanges else { return false }
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }  // closed meanwhile
        let wasActive = id == activeTabID
        remove(tab)
        if wasActive {
            activeTabID = nil
            if !tabs.isEmpty { try? select(tabs[min(index, tabs.count - 1)].id) }
        }
        return true
    }

    /// Closes every tab except `id` (one that cannot be saved stays).
    func closeOtherTabs(keeping id: UUID) async {
        for tab in tabs where tab.id != id {
            await closeTab(tab.id)
        }
    }

    /// A restored tab (see `restoreTabs`); its claim is already made.
    func appendRestored(_ tab: NotebookTab) {
        tabs.append(tab)
    }

    /// Moves a tab to `index` in the strip (dragging to reorder).
    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
    }

    /// Closes the shown tab (see `closeTab`).
    func close() async {
        if let activeTabID { await closeTab(activeTabID) }
    }

    /// Starts a save of every loaded notebook that iPadOS lets finish in the background
    /// (the app leaves the foreground).
    func saveAllInBackground() {
        for case let notebook? in tabs.map(\.notebook) {
            BackgroundSave.flush(notebook)
        }
    }

    private func activate(_ tab: NotebookTab) {
        if tab.id != activeTabID { leaveCurrent() }
        useCounter += 1
        tab.lastUsed = useCounter
        activeTabID = tab.id
        releaseOldTabs()
    }

    /// The tab that goes to the background is saved right away instead of after the usual
    /// autosave delay, so a later release or the app leaving finds it on disk.
    private func leaveCurrent() {
        guard let notebook = activeTab?.notebook else { return }
        beforeLeavingTab?()
        Task { await notebook.saveChanges() }
    }

    private func remove(_ tab: NotebookTab) {
        tabs.removeAll { $0.id == tab.id }
        registry.release(tab.url)
        if activeTabID == tab.id { activeTabID = nil }
    }

    /// The loaded tabs that may keep their model: the most recently used ones.
    private var recentTabIDs: Set<UUID> {
        Set(tabs.filter(\.isLoaded).sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.loadedTabLimit).map(\.id))
    }

    /// Saves and releases loaded tabs beyond the limit, one after another. A tab whose save
    /// fails stays loaded (more than the limit, but no ink is lost) and tries again next time.
    private func releaseOldTabs() {
        let old = tabs.filter { $0.isLoaded && !recentTabIDs.contains($0.id) }
        guard !old.isEmpty else { return }
        let previous = releaseTask
        releaseTask = Task {
            await previous?.value
            for tab in old {
                await tab.notebook?.saveChanges()
                // The tab may have been shown or closed during the save.
                guard tabs.contains(where: { $0 === tab }), tab.id != activeTabID, !recentTabIDs.contains(tab.id)
                else { continue }
                _ = tab.releaseIfSaved()
            }
        }
    }

    // MARK: Library changes (tabs step 4)

    /// Tabs taken off their notebooks while the library renames, moves or trashes them.
    struct DetachedTabs {
        fileprivate(set) var tabs: [NotebookTab] = []
        static let none = DetachedTabs()
    }

    /// Prepares a library action on `url` (a notebook or a folder): this window's tabs at or
    /// inside it are saved, released and their claims freed, so the files can change. Refused
    /// when another window has something there open, when one of them is the shown tab, or
    /// when a tab cannot be saved. Afterwards call `reattach`, also when the action failed.
    func detachTabs(under url: URL) async throws -> DetachedTabs {
        let claims = registry.claims(under: url)
        guard !claims.isEmpty else { return .none }
        guard claims.allSatisfy({ $0.owner?.window == windowID }) else { throw LibraryError.openInAnotherWindow }
        let ids = Set(claims.compactMap { $0.owner?.tab })
        let found = tabs.filter { ids.contains($0.id) }
        for tab in found {
            guard tab.id != activeTabID else { throw LibraryError.isOpen }
            await tab.notebook?.saveChanges()
            guard tab.releaseIfSaved() else { throw LibraryError.tabNotSaved(tab.title) }
        }
        // The shown tab may have changed during the saves.
        guard !found.contains(where: { $0.id == activeTabID }) else { throw LibraryError.isOpen }
        for tab in found {
            tab.isDetached = true  // not shown or closed until `reattach`
            registry.release(tab.url)
        }
        return DetachedTabs(tabs: found)
    }

    /// After a library action: the tabs follow their notebooks from `old` to `new` (a rename or
    /// a move; for a folder, every notebook inside moves with it), or close when `new` is nil
    /// (trashed). A tab whose notebook another window claimed meanwhile is closed.
    func reattach(_ detached: DetachedTabs, movedFrom old: URL, to new: URL?) {
        for tab in detached.tabs {
            tab.isDetached = false
            guard tabs.contains(where: { $0 === tab }) else { continue }  // closed meanwhile: claim nothing
            guard let new else {
                tabs.removeAll { $0 === tab }
                continue
            }
            let url = Self.rebase(tab.url, from: old, to: new)
            if registry.claim(url, by: NotebookOwner(window: windowID, tab: tab.id)) {
                tab.relocate(to: url)
            } else {
                tabs.removeAll { $0 === tab }
            }
        }
    }

    /// Renames a tab's notebook (its title and its `.inkbook` name, as in the library). The shown
    /// tab is closed in the editor for the moment (typing finished, saved), renamed, and shown
    /// again at the same spot.
    func renameTab(_ id: UUID, to name: String) async throws {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let wasShown = id == activeTabID
        if wasShown { showLibrary() }  // the editor stores its position and goes away
        let old = tab.url
        let operations = LibraryOperations(location: .documents, registry: registry)
        do {
            let detached = try await detachTabs(under: old)
            do {
                let new = try await Task.detached { try operations.rename(old, to: name) }.value
                reattach(detached, movedFrom: old, to: new)
            } catch {
                reattach(detached, movedFrom: old, to: old)
                throw error
            }
        } catch {
            if wasShown { try? select(id) }
            throw error
        }
        if wasShown { try select(id) }
    }

    /// `url` after its folder (or itself) moved from `old` to `new`.
    static func rebase(_ url: URL, from old: URL, to new: URL) -> URL {
        let path = OpenNotebookRegistry.key(url).path, oldPath = OpenNotebookRegistry.key(old).path
        if path == oldPath { return new }
        guard path.hasPrefix(oldPath + "/") else { return url }
        return new.appending(path: String(path.dropFirst(oldPath.count + 1)))
    }

    // MARK: Opening and going home with an animation

    /// While a notebook fades in over the library (see `openAnimated`).
    private(set) var isOpening = false
    private(set) var openRevealed = false

    /// Opens a notebook (a new tab, or its existing one) with the mirror image of
    /// `showLibraryAnimated`: the notebook opens at once and the editor is built invisibly on
    /// top of the library (the heavy part, done while nothing moves), then it grows from 94 %
    /// to full size while it fades in, then the library is removed.
    func openAnimated(_ package: NotebookPackage) async throws {
        try await revealAnimated { try self.open(package) }
    }

    /// Shows a tab from the library with the same animation as opening.
    func selectAnimated(_ id: UUID) async throws {
        try await revealAnimated { try self.select(id) }
    }

    private func revealAnimated(_ show: () throws -> Void) async throws {
        guard !isOpening, !isClosing else { return }
        TransitionGate.isActive = true
        defer { TransitionGate.isActive = false }
        isOpening = true
        do {
            try show()
        } catch {
            isOpening = false
            throw error
        }
        try? await Task.sleep(for: .milliseconds(150))  // the editor lays itself out
        withAnimation(.easeInOut(duration: 0.3)) { openRevealed = true }
        try? await Task.sleep(for: .milliseconds(330))
        isOpening = false
        openRevealed = false
    }

    /// While the editor fades out and the library shows through (see `showLibraryAnimated`).
    private(set) var isClosing = false
    private(set) var closeFaded = false

    /// Home with an animation: the library appears underneath, the editor shrinks a little and
    /// fades out. The tab stays open and is saved in the background.
    func showLibraryAnimated() async {
        guard notebook != nil, !isClosing else { return }
        TransitionGate.isActive = true
        defer { TransitionGate.isActive = false }
        isClosing = true  // the library is built underneath
        try? await Task.sleep(for: .milliseconds(150))  // it loads its tiles first
        withAnimation(.easeInOut(duration: 0.3)) { closeFaded = true }
        try? await Task.sleep(for: .milliseconds(330))
        showLibrary()
        isClosing = false
        closeFaded = false
    }

    // MARK: Importing

    /// Set when an import failed; the window shows it in an alert and clears it.
    var importError: String?

    /// Imports PDFs as new notebooks and opens the last one that worked in a new tab.
    /// Failures are collected in `importError` (one bad file does not stop the others).
    func importPDFs(_ urls: [URL]) async {
        var imported: NotebookPackage?
        var failures: [String] = []
        for url in urls {
            guard PDFImporter.isPDF(url) else {
                failures.append("\(url.lastPathComponent): this is not a PDF file.")
                continue
            }
            do {
                imported = try await PDFImporter.importPDF(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        guard let imported else { return }
        do {
            try open(imported)
        } catch {
            importError = error.localizedDescription
        }
    }
}
