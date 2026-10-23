import Foundation
import Observation
import PDFKit
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

    /// The notebook's PDF. This one object is shown by the editor's `PDFView` and changed by
    /// the page operations (`Notebook+Pages.swift`), so the screen follows the model. `nil`
    /// when the PDF cannot be read or does not have as many pages as `meta.pages` (SPEC,
    /// "File format"): the notebook then cannot be shown or changed, see `structureProblem`.
    private(set) var document: PDFDocument?
    private(set) var structureProblem: String?

    /// Which page id belongs to which `PDFPage` object. PDFKit asks for a page's overlay in
    /// the middle of `document.insert(...)`, when the PDF already has a new page but the page
    /// list does not yet, so a page's id cannot be worked out from its position in the PDF
    /// (measured: that gave canvases the wrong page's ink). The page object itself is the
    /// reliable key. Weak keys: a page that is gone for good takes its entry with it.
    @ObservationIgnored private let pageIDsByPage = NSMapTable<PDFPage, NSUUID>.weakToStrongObjects()

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

    /// True while the page list or the PDF changed and is not yet on disk (see
    /// `setPageList`). Counted like a page's revision, so a change made during a save is
    /// not wrongly marked as saved.
    @ObservationIgnored private(set) var structureDirty = false
    @ObservationIgnored private var structureRevision = 0

    /// Called after a page operation changed the page list or a page (also by undo and redo).
    /// The editor refreshes its `PDFView` here.
    @ObservationIgnored var onStructureChange: (() -> Void)?

    /// True while an object (image, text box) or the outline changed and `meta.json` is not yet
    /// written. Both live in `meta.json`, so saving them never rewrites the PDF. Counted like the
    /// page list, so a change made during a save is not wrongly marked as saved.
    @ObservationIgnored private(set) var metaDirty = false
    @ObservationIgnored private var metaRevision = 0

    /// Marks `meta.json` as changed (objects, outline) and schedules autosave.
    func markMetaChanged() {
        metaDirty = true
        metaRevision += 1
        scheduleAutosave()
    }

    /// Called with a page id after that page's objects changed (also by undo and redo). A
    /// visible page shows the new objects; the editor sets this.
    @ObservationIgnored var onObjectsChange: ((UUID) -> Void)?

    /// Anything not yet written: ink, objects or page changes.
    var hasUnsavedChanges: Bool { !dirtyPageIDs.isEmpty || structureDirty || metaDirty }

    /// How long after the last change autosave waits (SPEC: about 2 seconds).
    @ObservationIgnored var autosaveDelay: Duration = .seconds(2)

    /// Test seam: runs after a save has chosen what to write and before it writes. Tests use
    /// it to change the notebook in the middle of a save. Always `nil` in the app.
    @ObservationIgnored var saveHook: (@Sendable () async -> Void)?

    /// Counts changes per page. A save only marks a page as saved if its count is still the
    /// one the save wrote, so a stroke added during a save is never wrongly marked as saved.
    /// Observable on purpose: thumbnails read it to know when a page's picture is out of date.
    private(set) var revisions: [UUID: Int] = [:]

    /// Which pages are on screen right now; the editor sets this. Drawings of other pages that
    /// are saved can be dropped from memory (see `evictOffscreenDrawings`).
    @ObservationIgnored var visiblePageIDs: () -> Set<UUID> = { [] }
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
        // Every ink undo step keeps the page's whole old drawing. On a whiteboard that is the
        // whole board: about 1.6 MB per step at 5000 strokes (measured), so its history is capped.
        if meta.isWhiteboard { undoManager.levelsOfUndo = Whiteboard.undoLevels }
        if let document = PDFDocument(url: package.pdfURL), document.pageCount == meta.pages.count {
            self.document = document
            for (index, page) in meta.pages.enumerated() {
                if let pdfPage = document.page(at: index) { pageIDsByPage.setObject(page.id as NSUUID, forKey: pdfPage) }
            }
        } else {
            structureProblem = "This notebook cannot be changed: its page list and its PDF do not match. Nothing was changed."
        }
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
        // A page change that was interrupted by a crash is finished (or thrown away) first.
        try package.finishPendingCommit()
        return Notebook(package: package, meta: try package.readMeta())
    }

    var pages: [PageMeta] { meta.pages }

    /// The id of the page that `page` is (or was, or is about to become) in this notebook.
    func pageID(for page: PDFPage) -> UUID? {
        pageIDsByPage.object(forKey: page) as UUID?
    }

    /// Must be called before the page goes into `document`.
    func register(_ page: PDFPage, as id: UUID) {
        pageIDsByPage.setObject(id as NSUUID, forKey: page)
    }

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

    /// Pages whose drawing is currently held in memory (for tests and tuning).
    var loadedPageIDs: Set<UUID> { Set(drawings.keys) }

    /// Frees the memory of drawings that are safely on disk and not needed right now, so
    /// scrolling through a 300-page PDF does not keep every page's ink. A drawing is only
    /// dropped if it is not on screen, has no unsaved change (`dirtyPageIDs` is only cleared
    /// once the write succeeded) and was read from disk without trouble (an unreadable file
    /// keeps its empty stand-in, see `unreadablePageIDs`). The next `drawing(for:)` simply
    /// loads it again.
    func evictOffscreenDrawings() {
        evictDrawings(keeping: visiblePageIDs())
    }

    func evictDrawings(keeping visiblePageIDs: Set<UUID>) {
        let evictable = drawings.keys.filter {
            !visiblePageIDs.contains($0) && !dirtyPageIDs.contains($0) && !unreadablePageIDs.contains($0)
        }
        for pageID in evictable { drawings[pageID] = nil }
    }

    /// Stores a drawing for a page without an undo step of its own; page operations use it
    /// for the ink of new pages (the operation's own undo step removes the page again).
    func storeDrawing(_ drawing: PKDrawing, for pageID: UUID) {
        drawings[pageID] = drawing
        dirtyPageIDs.insert(pageID)
        revisions[pageID, default: 0] += 1
        scheduleAutosave()
    }

    /// The only place that changes the page list. Page operations call it after they changed
    /// `document`, so the list and the PDF always change together. Saved with the next autosave.
    func setPageList(_ pages: [PageMeta]) {
        meta.pages = pages
        structureDirty = true
        structureRevision += 1
        scheduleAutosave()
        onStructureChange?()
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

    // MARK: Objects

    /// The images and text boxes of a page, from bottom to top.
    func objects(on pageID: UUID) -> [PageObject] {
        meta.pages.first { $0.id == pageID }?.objects ?? []
    }

    /// Replaces a page's objects and records one undo step. Every change to objects (add,
    /// move, resize, edit, delete; see `Notebook+Objects.swift`) comes through here, like
    /// `setDrawing` for ink. Does nothing for a page that is not in the notebook.
    func setObjects(_ newObjects: [PageObject], for pageID: UUID, actionName: String) {
        guard let index = meta.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let oldObjects = meta.pages[index].objects
        guard newObjects != oldObjects else { return }

        performUndoableChange(actionName) {
            meta.pages[index].objects = newObjects
            revisions[pageID, default: 0] += 1  // thumbnails redraw
            markMetaChanged()
            undoManager.registerUndo(withTarget: self) { notebook in
                MainActor.assumeIsolated {
                    notebook.setObjects(oldObjects, for: pageID, actionName: actionName)
                }
            }
            onObjectsChange?(pageID)
        }
    }

    // MARK: Outline

    /// The stored outline; `nil` until it was set up (see `Notebook+Outline.swift`).
    var outline: [OutlineEntry]? { meta.outline }

    /// Replaces the outline and records one undo step, like `setObjects`. Every outline change
    /// (add, rename, indent, delete, generate) comes through here.
    func setOutline(_ newOutline: [OutlineEntry], actionName: String) {
        let oldOutline = meta.outline
        guard newOutline != oldOutline else { return }
        performUndoableChange(actionName) {
            meta.outline = newOutline
            markMetaChanged()
            undoManager.registerUndo(withTarget: self) { notebook in
                MainActor.assumeIsolated {
                    notebook.setOutline(oldOutline ?? [], actionName: actionName)
                }
            }
        }
    }

    /// The first outline of a notebook (from its bookmarks or text): saved, but not an undo
    /// step, because the user did nothing. Ignored once an outline exists.
    func setUpOutline(_ entries: [OutlineEntry]) {
        guard meta.outline == nil else { return }
        meta.outline = entries
        markMetaChanged()
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

    /// A changed page list: the new PDF's bytes and the matching `meta.json`, written together.
    private struct StructureSnapshot: Sendable {
        let pdfData: Data
        let meta: NotebookMeta
        let revision: Int
    }

    private func performSave() async {
        let snapshots = dirtyPageIDs.map {
            PageSnapshot(
                pageID: $0, drawing: drawings[$0] ?? PKDrawing(), revision: revisions[$0] ?? 0,
                preserveExistingFile: unreadablePageIDs.contains($0))
        }
        // The PDF is turned into bytes here on the main thread (PDFKit objects are not for
        // other threads); only writing the bytes happens in the background.
        var structure: StructureSnapshot?
        var structureFailure: String?
        if structureDirty {
            if let document, let data = document.dataRepresentation() {
                meta.updatedAt = .now
                structure = StructureSnapshot(pdfData: data, meta: meta, revision: structureRevision)
            } else {
                structureFailure = "The notebook's PDF could not be prepared for saving."
            }
        }
        // Object changes only need `meta.json`; remember which change this save covers.
        let metaRevisionToSave: Int? = metaDirty ? metaRevision : nil
        guard !snapshots.isEmpty || structure != nil || structureFailure != nil || metaRevisionToSave != nil
        else { return }
        await saveHook?()

        // The file work runs off the main thread so writing never stutters the pen.
        let package = self.package
        let result = await Task.detached { () -> (saved: [PageSnapshot], structureSaved: Bool, failure: String?) in
            var saved: [PageSnapshot] = []
            var structureSaved = false
            var failure: String?
            if let structure {
                do {
                    try package.commitStructure(pdfData: structure.pdfData, meta: structure.meta)
                    structureSaved = true
                } catch {
                    failure = error.localizedDescription  // keep going: ink can still be saved
                }
            }
            for snapshot in snapshots {
                do {
                    if snapshot.preserveExistingFile {
                        try package.preserveUnreadableDrawing(for: snapshot.pageID)
                    }
                    try package.saveDrawing(snapshot.drawing, for: snapshot.pageID)
                    saved.append(snapshot)
                } catch {
                    failure = failure ?? error.localizedDescription  // other pages may still save
                }
            }
            return (saved, structureSaved, failure)
        }.value

        var failure = result.failure ?? structureFailure
        if result.structureSaved, let structure, structureRevision == structure.revision {
            structureDirty = false
            // The committed meta.json holds the objects as they were when the save began.
            if metaRevisionToSave == metaRevision { metaDirty = false }
        }
        for snapshot in result.saved {
            unreadablePageIDs.remove(snapshot.pageID)  // its old file is now safely copied aside
            if revisions[snapshot.pageID] == snapshot.revision {
                dirtyPageIDs.remove(snapshot.pageID)
            }
        }
        // meta.json is only written alone when the page list on disk is current: writing a
        // newer page list without its PDF would make the two disagree. (When the page list
        // was saved this round, the commit above already wrote meta.json.)
        if !result.saved.isEmpty || metaDirty, !structureDirty, !result.structureSaved {
            meta.updatedAt = .now
            // Written now, on the main thread, so this is the newest objects state.
            let writtenMetaRevision = metaRevision
            do {
                try package.writeMeta(meta)
                if metaRevision == writtenMetaRevision { metaDirty = false }
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        saveError = failure
    }
}
