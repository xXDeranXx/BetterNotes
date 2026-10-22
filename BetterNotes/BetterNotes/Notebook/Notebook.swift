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

    /// Why the last save failed, for the banner in the editor; `nil` when everything is saved.
    private(set) var saveError: String?

    /// Pages whose saved drawing file could not be read. Their drawing starts empty, but the
    /// file on disk must not be overwritten blindly: autosave keeps a copy first (step 6).
    @ObservationIgnored private(set) var unreadablePageIDs: Set<UUID> = []

    /// How long after the last change autosave waits (SPEC: about 2 seconds).
    @ObservationIgnored var autosaveDelay: Duration = .seconds(2)

    /// Test seam: runs after a save has chosen what to write and before it writes. Tests use
    /// it to change the notebook in the middle of a save. Always `nil` in the app.
    @ObservationIgnored var saveHook: (@Sendable () async -> Void)?

    /// Counts changes per page. A save only marks a page as saved if its count is still the
    /// one the save wrote, so a stroke added during a save is never wrongly marked as saved.
    @ObservationIgnored private var revisions: [UUID: Int] = [:]
    @ObservationIgnored private var savingTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

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
            revisions[pageID, default: 0] += 1
            scheduleAutosave()
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

    // MARK: Saving

    /// Writes every changed page's drawing, then updates `meta.json`. Returns when everything
    /// that was changed before the call has been written, or has failed (see `saveError`).
    /// Saves run one after the other, never at the same time. Safe to call at any time.
    func saveChanges() async {
        autosaveTask?.cancel()
        let previous = savingTask
        let task = Task { [self] in
            await previous?.value
            await performSave()
        }
        savingTask = task
        await task.value
    }

    /// Waits `autosaveDelay` after the last change, then saves. Every new change restarts the wait.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.saveChanges()
        }
    }

    private struct PageSnapshot: Sendable {
        let pageID: UUID
        let drawing: PKDrawing
        let revision: Int
        /// The file on disk could not be read: keep a copy before replacing it.
        let preserveExistingFile: Bool
    }

    private func performSave() async {
        let snapshots = dirtyPageIDs.map {
            PageSnapshot(
                pageID: $0, drawing: drawings[$0] ?? PKDrawing(), revision: revisions[$0] ?? 0,
                preserveExistingFile: unreadablePageIDs.contains($0))
        }
        guard !snapshots.isEmpty else { return }
        await saveHook?()

        // The file work runs off the main thread so writing never stutters the pen.
        let package = self.package
        let result = await Task.detached { () -> (saved: [PageSnapshot], failure: String?) in
            var saved: [PageSnapshot] = []
            var failure: String?
            for snapshot in snapshots {
                do {
                    if snapshot.preserveExistingFile {
                        try package.preserveUnreadableDrawing(for: snapshot.pageID)
                    }
                    try package.saveDrawing(snapshot.drawing, for: snapshot.pageID)
                    saved.append(snapshot)
                } catch {
                    failure = error.localizedDescription  // keep going: other pages may still save
                }
            }
            return (saved, failure)
        }.value

        var failure = result.failure
        for snapshot in result.saved {
            unreadablePageIDs.remove(snapshot.pageID)  // its old file is now safely copied aside
            if revisions[snapshot.pageID] == snapshot.revision {
                dirtyPageIDs.remove(snapshot.pageID)
            }
        }
        if !result.saved.isEmpty {
            meta.updatedAt = .now
            do {
                try package.writeMeta(meta)
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        saveError = failure
    }
}
