import CoreGraphics
import Foundation
import Observation

/// Where a tab was scrolled to, so coming back shows the same spot: a page by id (never by
/// number, see "Rules learned"), a point on that page in page coordinates, and the zoom.
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
        self.notebook = notebook
    }

    var isLoaded: Bool { notebook != nil }

    /// Loads the model again if the tab was released.
    func load() throws -> Notebook {
        if let notebook { return notebook }
        let notebook = try Notebook.open(NotebookPackage(url: url))
        self.notebook = notebook
        title = notebook.meta.title
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
