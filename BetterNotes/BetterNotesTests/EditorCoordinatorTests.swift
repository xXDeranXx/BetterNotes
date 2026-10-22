import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Tests with real `PKCanvasView`s (they work without a window).
@MainActor
struct EditorCoordinatorTests {
    private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let coordinator: EditorCoordinator
        let pageA: UUID
        let pageB: UUID
    }

    private func makeSetup() throws -> Setup {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var meta = try package.readMeta()
        meta.pages.append(PageMeta(template: .lined, size: .a4Portrait))
        try package.writeMeta(meta)
        let notebook = try Notebook.open(package)
        return Setup(
            folder: folder, notebook: notebook, coordinator: EditorCoordinator(notebook: notebook),
            pageA: notebook.pages[0].id, pageB: notebook.pages[1].id)
    }

    /// What PencilKit does when the user finishes a stroke: the canvas changes, then calls its delegate.
    private func userDraws(_ drawing: PKDrawing, on overlay: PageOverlayView, using coordinator: EditorCoordinator) {
        overlay.canvas.drawing = drawing
        coordinator.canvasViewDrawingDidChange(overlay.canvas)
    }

    @Test func aFinishedStrokeReachesTheModelAsOneUndoStep() throws {
        let setup = try makeSetup()
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.canvas.delegate = setup.coordinator
        setup.coordinator.overlayDidAppear(overlay)

        userDraws(sampleDrawing(), on: overlay, using: setup.coordinator)

        #expect(setup.notebook.drawing(for: setup.pageA).strokes.count == 1)
        setup.notebook.undoManager.undo()
        #expect(!setup.notebook.undoManager.canUndo)  // exactly one step, no echo steps
    }

    @Test func undoUpdatesTheVisibleCanvasWithoutCreatingAStepOrLosingRedo() throws {
        let setup = try makeSetup()
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.canvas.delegate = setup.coordinator
        setup.coordinator.overlayDidAppear(overlay)
        userDraws(sampleDrawing(), on: overlay, using: setup.coordinator)

        setup.notebook.undoManager.undo()

        #expect(overlay.canvas.drawing.strokes.isEmpty)  // the canvas follows the model
        #expect(setup.notebook.undoManager.canRedo)  // the echo did not wipe redo
        #expect(!setup.notebook.undoManager.canUndo)

        setup.notebook.undoManager.redo()

        #expect(overlay.canvas.drawing.strokes.count == 1)
        #expect(setup.notebook.undoManager.canUndo)
        #expect(!setup.notebook.undoManager.canRedo)
    }

    @Test func aCanvasThatAppearsLaterShowsChangesMadeWhileItWasOffScreen() throws {
        let setup = try makeSetup()
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.canvas.delegate = setup.coordinator
        setup.coordinator.overlayDidAppear(overlay)
        userDraws(sampleDrawing(), on: overlay, using: setup.coordinator)

        // Scroll away: the page's canvas is dropped. Then undo its stroke.
        setup.coordinator.overlayDidDisappear(overlay)
        #expect(setup.coordinator.visibleOverlays.isEmpty)
        setup.notebook.undoManager.undo()
        #expect(setup.notebook.drawing(for: setup.pageA).strokes.isEmpty)

        // Scroll back: PDFKit may hand us the same or a new overlay; it must show the model.
        setup.coordinator.overlayDidAppear(overlay)
        #expect(overlay.canvas.drawing.strokes.isEmpty)
    }

    @Test func eachVisibleCanvasOnlyShowsItsOwnPage() throws {
        let setup = try makeSetup()
        let overlayA = PageOverlayView(pageID: setup.pageA)
        let overlayB = PageOverlayView(pageID: setup.pageB)
        for overlay in [overlayA, overlayB] {
            overlay.canvas.delegate = setup.coordinator
            setup.coordinator.overlayDidAppear(overlay)
        }

        userDraws(sampleDrawing(), on: overlayB, using: setup.coordinator)

        #expect(setup.notebook.drawing(for: setup.pageA).strokes.isEmpty)
        #expect(setup.notebook.drawing(for: setup.pageB).strokes.count == 1)
        #expect(overlayA.canvas.drawing.strokes.isEmpty)
    }

    @Test func pencilKitsOwnUndoNeverRecordsAnything() throws {
        let overlay = PageOverlayView(pageID: UUID())
        let notebookManager = UndoManager()

        let canvasManager = try #require(overlay.canvas.undoManager)
        canvasManager.registerUndo(withTarget: overlay) { _ in }

        #expect(!canvasManager.canUndo)
        #expect(canvasManager !== notebookManager)
        #expect(!overlay.canvas.canBecomeFirstResponder)
    }

    @Test func theOverlayHasTheThreeLayersInOrder() {
        let overlay = PageOverlayView(pageID: UUID())

        #expect(overlay.subviews == [overlay.objectsLayer, overlay.canvas, overlay.previewLayer])
        #expect(!overlay.objectsLayer.isUserInteractionEnabled)
        #expect(!overlay.previewLayer.isUserInteractionEnabled)
    }

    @Test func undoRoutingViewUsesTheNotebooksUndoManager() throws {
        let setup = try makeSetup()

        let view = UndoRoutingView(notebook: setup.notebook)

        #expect(view.undoManager === setup.notebook.undoManager)
        #expect(view.canBecomeFirstResponder)
    }

    @Test func undoAndRedoButtonsFollowTheUndoManager() throws {
        let setup = try makeSetup()
        #expect(!setup.notebook.canUndo && !setup.notebook.canRedo)

        setup.notebook.setDrawing(sampleDrawing(), for: setup.pageA)
        #expect(setup.notebook.canUndo && !setup.notebook.canRedo)

        setup.notebook.undoManager.undo()
        #expect(!setup.notebook.canUndo && setup.notebook.canRedo)

        setup.notebook.undoManager.redo()
        #expect(setup.notebook.canUndo && !setup.notebook.canRedo)
    }

    @Test func pagesAreMappedToIDsByIndex() throws {
        let setup = try makeSetup()
        let document = try #require(PDFDocument(url: setup.notebook.package.pdfURL))
        // The test notebook's PDF has 1 page but meta lists 2: page 0 maps, the rest is unmapped.
        let first = try #require(document.page(at: 0))

        #expect(setup.coordinator.pageID(for: first) == setup.pageA)
    }
}
