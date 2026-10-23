import CoreGraphics
import Foundation
import Observation

/// Where a tab was scrolled to, so coming back shows the same spot: a page by id (never by
/// number, see "Rules learned"), the point of that page at the top left of the visible area
/// (below the toolbar), in PDFKit's page coordinates (as `PDFDestination` wants them), and the zoom.
nonisolated struct TabPosition: Codable, Equatable, Sendable {
    var pageID: UUID
    var point: CGPoint
    var zoom: CGFloat
}

/// One open notebook in a window's tab strip. A tab is **loaded** while it holds its
/// `Notebook` model (and with it the undo history), or **released** down to its URL, title
/// and position. Either way it keeps its claim in the registry, so the notebook counts as open.
/// Only the active tab has an editor; a loaded background tab has no views, so it costs no
/// rendering, only the memory of its model.
@Observable
final class NotebookTab: Identifiable {
    let id: UUID
    private(set) var url: URL
    private(set) var title: String
    /// The notebook's id from `meta.json`, so a restored tab finds a moved notebook again.
    private(set) var notebookID: UUID?
    /// nil while released.
    private(set) var notebook: Notebook?
    /// Set by the editor while the tab is on screen.
    var position: TabPosition?
    /// When the tab was last shown, to know which tabs stay loaded (bigger = more recent).
    @ObservationIgnored var lastUsed = 0

    init(id: UUID = UUID(), notebook: Notebook) {
        self.id = id
        self.url = notebook.package.url
        self.title = notebook.meta.title
        self.notebookID = notebook.meta.id
        self.notebook = notebook
    }

    /// A released tab (restored after a launch): only the title is read now, the notebook
    /// loads when the tab is shown.
    init(releasedAt url: URL, notebookID: UUID?) {
        self.id = UUID()
        self.url = url
        self.notebookID = notebookID
        self.title = (try? NotebookPackage(url: url).readMeta().title) ?? url.deletingPathExtension().lastPathComponent
    }

    var isLoaded: Bool { notebook != nil }

    /// The notebook was renamed or moved in the library while this tab was released.
    func relocate(to newURL: URL) {
        precondition(notebook == nil, "only a released tab can follow its notebook")
        url = newURL
        if let meta = try? NotebookPackage(url: newURL).readMeta() {
            title = meta.title
            notebookID = meta.id
        }
    }

    /// Loads the model again if the tab was released.
    func load() throws -> Notebook {
        if let notebook { return notebook }
        let notebook = try Notebook.open(NotebookPackage(url: url))
        self.notebook = notebook
        title = notebook.meta.title
        notebookID = notebook.meta.id
        return notebook
    }

    /// Drops the model, but only if everything is on disk; `false` keeps it loaded.
    func releaseIfSaved() -> Bool {
        guard let notebook else { return true }
        guard !notebook.hasUnsavedChanges else { return false }
        title = notebook.meta.title
        self.notebook = nil
        return true
    }
}
