import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Records the canvas's zoom at the moment its drawing is assigned (PencilKit calls the
/// delegate synchronously when code sets `canvas.drawing`).
@MainActor
private final class ZoomAtAssignmentSpy: NSObject, PKCanvasViewDelegate {
    var zoomScales: [CGFloat] = []
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { zoomScales.append(canvasView.zoomScale) }
}

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

    @Test func canvasRenderScaleFollowsTheZoomButIsCapped() {
        #expect(EditorCoordinator.renderScale(zoom: 0.5) == 1)  // zoomed out: never below the page size
        #expect(EditorCoordinator.renderScale(zoom: 1.36) == 2)  // fit to width on an iPad
        #expect(EditorCoordinator.renderScale(zoom: 3) == 3)
        #expect(EditorCoordinator.renderScale(zoom: 6) == 6)
        #expect(EditorCoordinator.renderScale(zoom: 50) == EditorCoordinator.maxRenderScale)
    }

    @Test func aMagnifiedCanvasStillCoversExactlyThePageAndKeepsPageCoordinates() {
        let overlay = PageOverlayView(pageID: UUID())
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        overlay.renderScale = 3
        overlay.layoutIfNeeded()

        // The canvas is 3x bigger inside, shrunk back by 1/3: on screen it is the page.
        #expect(overlay.canvas.bounds.size == CGSize(width: 595 * 3, height: 842 * 3))
        let onScreen = overlay.convert(overlay.canvas.bounds, from: overlay.canvas)
        #expect(abs(onScreen.width - 595) < 0.001 && abs(onScreen.height - 842) < 0.001)
        #expect(abs(onScreen.minX) < 0.001 && abs(onScreen.minY) < 0.001)
        #expect(overlay.canvas.zoomScale == 3)
        // A point in page coordinates is where the drawing keeps it, whatever the render scale.
        #expect(overlay.canvas.convert(CGPoint(x: 300, y: 400), from: overlay.canvas) == CGPoint(x: 300, y: 400))
    }

    @Test func aSavedDrawingIsAssignedOnlyAfterTheCanvasHasItsFinalZoom() throws {
        // Regression: when the drawing was assigned first and the canvas magnified afterwards,
        // PencilKit left the ink invisible after reopening a notebook (found with a UI test).
        let setup = try makeSetup()
        setup.notebook.setDrawing(sampleDrawing(), for: setup.pageA)
        setup.coordinator.zoomDidChange(to: 3)
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        let spy = ZoomAtAssignmentSpy()
        overlay.canvas.delegate = spy

        setup.coordinator.overlayDidAppear(overlay)

        #expect(overlay.canvas.drawing.strokes.count == 1)
        #expect(spy.zoomScales == [3])  // assigned once, and already at the final zoom
    }

    @Test func inkResolutionIsLoweredWhenTheIPadGetsHotAndRestoredWhenItCools() throws {
        let setup = try makeSetup()
        setup.coordinator.zoomDidChange(to: 5)
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        setup.coordinator.overlayDidAppear(overlay)
        #expect(overlay.renderScale == 5)

        setup.coordinator.thermalStateDidChange(to: .fair)  // warm is fine
        #expect(overlay.renderScale == 5)
        setup.coordinator.thermalStateDidChange(to: .serious)
        #expect(overlay.renderScale == 2)
        setup.coordinator.thermalStateDidChange(to: .critical)
        #expect(overlay.renderScale == 1)
        setup.coordinator.thermalStateDidChange(to: .nominal)
        #expect(overlay.renderScale == 5)
    }

    @Test func aPageThatScrollsInWhileHotStartsAtTheLoweredResolution() throws {
        let setup = try makeSetup()
        setup.coordinator.zoomDidChange(to: 4)
        setup.coordinator.thermalStateDidChange(to: .serious)
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)

        setup.coordinator.overlayDidAppear(overlay)

        #expect(overlay.renderScale == 2)
        #expect(overlay.canvas.zoomScale == 2)
    }

    @Test func aHotIPadStartsTheEditorAtTheLoweredResolution() throws {
        let setup = try makeSetup()
        let hotCoordinator = EditorCoordinator(notebook: setup.notebook, thermalState: .critical)
        hotCoordinator.zoomDidChange(to: 3)
        let overlay = PageOverlayView(pageID: setup.pageA)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)

        hotCoordinator.overlayDidAppear(overlay)

        #expect(overlay.renderScale == 1)
    }

    @Test func theResolutionCapFollowsTheThermalState() {
        #expect(EditorCoordinator.renderScaleCap(for: .nominal) == EditorCoordinator.maxRenderScale)
        #expect(EditorCoordinator.renderScaleCap(for: .fair) == EditorCoordinator.maxRenderScale)
        #expect(EditorCoordinator.renderScaleCap(for: .serious) == 2)
        #expect(EditorCoordinator.renderScaleCap(for: .critical) == 1)
        // The cap never raises the scale above what the zoom needs, and never goes below 1.
        #expect(EditorCoordinator.renderScale(zoom: 1.2, cap: 2) == 2)
        #expect(EditorCoordinator.renderScale(zoom: 0.4, cap: 1) == 1)
    }
}
