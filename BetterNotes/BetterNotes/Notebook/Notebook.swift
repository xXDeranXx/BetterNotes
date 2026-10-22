import Foundation
import Observation
import PencilKit

/// The single source of truth for an open notebook (SPEC, architecture decisions 1, 2 and 5).
///
/// Canvases, thumbnails, the page grid and export all read from here, and autosave writes
/// from here. One `Notebook` exists per window that has the notebook open, so the undo
/// history is per window too and nothing here is global.
///
/// Undo works on data, not on views: every undo step is "set this page's drawing back to
/// what it was", registered on this object. No step ever points at a `PKCanvasView`, so
/// undo still works after the canvas was dropped while scrolling.
///
/// (The project runs everything on the main actor by default, so this class does too.)
@Observable
final class Notebook {
    let package: NotebookPackage
    private(set) var meta: NotebookMeta

    /// One history per notebook window. `groupsByEvent` is off: we group explicitly in
    /// `performUndoableChange`, so one user action is exactly one undo step.
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// For the Undo and Redo buttons. `UndoManager` itself is not observable, so these are
    /// refreshed from its notifications, which also covers Cmd+Z and shake to undo.
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Pages whose drawing changed since it was last written. Autosave (step 6) reads this.
    private(set) var dirtyPageIDs: Set<UUID> = []

    /// Pages whose saved drawing file could not be read. Their drawing starts empty, but the
    /// file on disk must not be overwritten blindly: autosave keeps a copy first (step 6).
    @ObservationIgnored private(set) var unreadablePageIDs: Set<UUID> = []

    /// Called with a page id after that page's drawing changed (by drawing, undo or redo).
    /// A visible canvas listens here and shows the new drawing; a dropped canvas does not
    /// listen, and the model changes anyway. The editor sets this; there is one editor.
    @ObservationIgnored var onDrawingChange: ((UUID) -> Void)?

    /// Drawings loaded so far, by page id. Loaded lazily, so a 300-page PDF opens fast.
    @ObservationIgnored private var drawings: [UUID: PKDrawing] = [:]

    init(package: NotebookPackage, meta: NotebookMeta) {
        self.package = package
        self.meta = meta
        // No observer cleanup needed: the observers are tied to this notebook's own
        // UndoManager and only hold `self` weakly.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoState() }
            }
        }
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    static func open(_ package: NotebookPackage) throws -> Notebook {
        Notebook(package: package, meta: try package.readMeta())
    }

    var pages: [PageMeta] { meta.pages }

    // MARK: Drawings

    /// The page's drawing; empty if it has none yet.
    func drawing(for pageID: UUID) -> PKDrawing {
        if let loaded = drawings[pageID] { return loaded }
        let drawing: PKDrawing
        do {
            drawing = try package.loadDrawing(for: pageID) ?? PKDrawing()
        } catch {
            unreadablePageIDs.insert(pageID)
            drawing = PKDrawing()
        }
        drawings[pageID] = drawing
        return drawing
    }

    /// Replaces a page's drawing and records one undo step. This is the only way ink
    /// changes, whether it comes from a canvas (the user drew) or from undo and redo.
    ///
    /// Setting the very same drawing value again is ignored. Note that `PKDrawing`'s `==`
    /// compares identity, not strokes: two separately built drawings are never equal, so the
    /// editor must not rely on this check to detect "nothing changed" (it uses the canvas
    /// delegate, which only fires on real changes).
    func setDrawing(_ newDrawing: PKDrawing, for pageID: UUID, actionName: String = "Draw") {
        let oldDrawing = drawing(for: pageID)
        guard newDrawing != oldDrawing else { return }

        performUndoableChange(actionName) {
            drawings[pageID] = newDrawing
            dirtyPageIDs.insert(pageID)
            // While undoing, UndoManager files this registration as the redo step.
            undoManager.registerUndo(withTarget: self) { notebook in
                // UndoManager's handler is not marked as main-actor code, but it runs on
                // the thread that called undo(), which is always the main thread here.
                MainActor.assumeIsolated {
                    notebook.setDrawing(oldDrawing, for: pageID, actionName: actionName)
                }
            }
            onDrawingChange?(pageID)
        }
    }

    // MARK: Undo grouping

    /// Runs `change` as one undo step. Nested calls (a page operation that changes several
    /// drawings, milestone 4) join the outer step. During undo and redo no new group is opened.
    func performUndoableChange(_ actionName: String, _ change: () -> Void) {
        if undoManager.isUndoing || undoManager.isRedoing {
            change()
            return
        }
        undoManager.beginUndoGrouping()
        change()
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }
}
