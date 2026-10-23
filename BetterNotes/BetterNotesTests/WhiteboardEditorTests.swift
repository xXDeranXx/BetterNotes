import Foundation
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// The whiteboard's board mode, with the real editor controller in a window.
@MainActor
struct WhiteboardEditorTests {
    private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let controller: NotebookEditorViewController
        let window: UIWindow
        var overlay: PageOverlayView { controller.view.subviews.compactMap { $0 as? PageOverlayView }.first! }
    }

    private func makeSetup(position: TabPosition? = nil) throws -> Setup {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Board", background: .dots, coverColor: "#3366CC"))
        notebook.autosaveDelay = .seconds(60)
        let controller = NotebookEditorViewController(notebook: notebook, search: DocumentSearch(), navigator: PageNavigator(notebook: notebook))
        controller.pendingPosition = position
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return Setup(folder: folder, notebook: notebook, controller: controller, window: window)
    }

    @Test func aNewBoardOpensInTheMiddleAtZoomOne() throws {
        let setup = try makeSetup()
        let overlay = setup.overlay
        #expect(overlay.isBoard && overlay.canvas.isScrollEnabled)
        #expect(overlay.canvas.zoomScale == 1)
        let visible = overlay.visibleBoardRect
        #expect(abs(visible.midX - 5000) < 1 && abs(visible.midY - 5000) < 1)
        #expect(overlay.canvas.minimumZoomScale == Whiteboard.minimumZoom)
    }

    @Test func screenPointsMapToBoardPointsAtAnyZoom() throws {
        let setup = try makeSetup()
        let overlay = setup.overlay
        overlay.showBoard(at: CGPoint(x: 3000, y: 2000), zoom: 2)
        // 100 x 50 screen points from the corner are 50 x 25 board points at zoom 2.
        let point = overlay.convert(CGPoint(x: 100, y: 50), to: overlay.pageSpace)
        #expect(abs(point.x - 3050) < 0.5 && abs(point.y - 2025) < 0.5)
        // The editing layer is in the same page space.
        let editing = overlay.convert(CGPoint(x: 100, y: 50), to: overlay.editingHost)
        #expect(abs(editing.x - 3050) < 0.5 && abs(editing.y - 2025) < 0.5)
    }

    @Test func zoomCannotGoBelowTheLimit() throws {
        let setup = try makeSetup()
        setup.overlay.showBoard(at: .zero, zoom: 0.1)
        #expect(setup.overlay.canvas.zoomScale == Whiteboard.minimumZoom)
    }

    @Test func theRememberedSpotComesBack() throws {
        let setup = try makeSetup(position: TabPosition(pageID: UUID(), point: CGPoint(x: 1200, y: 800), zoom: 1.5))
        let position = try #require(setup.controller.currentPosition())
        #expect(abs(position.point.x - 1200) < 1 && abs(position.point.y - 800) < 1)
        #expect(abs(position.zoom - 1.5) < 0.001)
    }

    @Test func aCanvasSwapKeepsThePlaceAndZoom() throws {
        let setup = try makeSetup()
        let overlay = setup.overlay
        overlay.showBoard(at: CGPoint(x: 2500, y: 4000), zoom: 3)
        let offset = overlay.canvas.contentOffset
        let new = overlay.replaceCanvas()
        #expect(new.isScrollEnabled)
        #expect(new.zoomScale == 3)
        #expect(abs(new.contentOffset.x - offset.x) < 0.5)
        #expect(abs(new.contentOffset.y - offset.y) < 0.5)
        #expect(new.panGestureRecognizer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)])
    }

    @Test func undoOnTheBoardShowsTheModelsInk() throws {
        let setup = try makeSetup()
        let overlay = setup.overlay
        let id = setup.notebook.pages[0].id
        let stroke = lineDrawing(from: CGPoint(x: 5000, y: 5000), to: CGPoint(x: 5200, y: 5000))
        overlay.canvas.drawing = stroke
        overlay.canvas.delegate?.canvasViewDrawingDidChange?(overlay.canvas)
        #expect(setup.notebook.drawing(for: id).strokes.count == 1)
        setup.notebook.undoManager.undo()
        #expect(setup.notebook.drawing(for: id).strokes.isEmpty)
        #expect(setup.overlay.canvas.drawing.strokes.isEmpty)
        #expect(setup.overlay.canvas.zoomScale == 1)  // the fresh canvas is at the same zoom
    }

    @Test func withTheSelectToolTheBoardStillScrolls() throws {
        let setup = try makeSetup()
        var settings = ToolSettings()
        settings.selected = .select
        setup.controller.applyTools(settings, isRulerActive: false)
        let canvas = setup.overlay.canvas
        #expect(canvas.isUserInteractionEnabled)  // it is the scroll view
        #expect(!canvas.drawingGestureRecognizer.isEnabled)  // but it does not draw
        #expect(setup.overlay.objectGesture.isEnabled)
    }

    @Test func newObjectsGoToTheMiddleOfTheScreen() throws {
        let setup = try makeSetup()
        setup.overlay.showBoard(at: CGPoint(x: 1000, y: 2000), zoom: 1)
        let target = try #require(setup.controller.pageAtScreenCenter())
        #expect(target.id == setup.notebook.pages[0].id)
        #expect(abs(target.point.x - 1400) < 1 && abs(target.point.y - 2500) < 1)
    }

    @Test func aShapeDrawnOnTheBoardLandsWhereItWasDrawn() throws {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Shapes", background: .plain, coverColor: "#3366CC"))
        let coordinator = EditorCoordinator(notebook: notebook)
        let page = notebook.pages[0]
        let overlay = coordinator.makeOverlay(pageID: page.id, boardSize: CGSize(width: page.size.width, height: page.size.height))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        window.makeKeyAndVisible()
        overlay.layoutIfNeeded()
        overlay.showBoard(at: CGPoint(x: 4000, y: 4000), zoom: 2)
        coordinator.overlayDidAppear(overlay)

        coordinator.addShape(ShapeSetting(), from: CGPoint(x: 4100, y: 4100), to: CGPoint(x: 4300, y: 4250), on: overlay)
        let bounds = notebook.drawing(for: page.id).bounds
        #expect(!bounds.isEmpty)
        #expect(bounds.insetBy(dx: -10, dy: -10).contains(CGRect(x: 4100, y: 4100, width: 200, height: 150)))
        #expect(bounds.width < 260)
        _ = window
    }

    @Test func aBigImageOnTheBoardFitsOnTheScreen() throws {
        let setup = try makeSetup()
        let overlay = setup.overlay
        let visible = overlay.visibleBoardRect
        let prepared = ObjectImageImport.Prepared(data: Data([0xFF, 0xD8]), fileExtension: "jpg", pixelSize: CGSize(width: 3000, height: 2000))
        let object = try setup.notebook.insertImage(
            prepared, on: setup.notebook.pages[0].id, center: CGPoint(x: visible.midX, y: visible.midY), area: visible.size)
        #expect(object.frame.width <= visible.width * 0.6 + 1 && object.frame.height <= visible.height * 0.6 + 1)
        #expect(visible.contains(object.frame))
    }

    @Test func aTwoFingerTapCountsOnlyWhenNothingMoved() {
        let start = ScrollSnapshot(zoom: 1, offset: CGPoint(x: 4000, y: 4000))
        #expect(start.isStill(comparedTo: ScrollSnapshot(zoom: 1.005, offset: CGPoint(x: 4002, y: 4001))))
        #expect(!start.isStill(comparedTo: ScrollSnapshot(zoom: 1.08, offset: CGPoint(x: 4000, y: 4000))))  // a pinch
        #expect(!start.isStill(comparedTo: ScrollSnapshot(zoom: 1, offset: CGPoint(x: 4030, y: 4000))))  // a scroll
    }

    @Test func aNotebookPageKeepsItsOwnCoordinates() {
        let overlay = PageOverlayView(pageID: UUID())
        #expect(!overlay.isBoard && overlay.pageSpace === overlay && overlay.editingHost === overlay)
        #expect(overlay.shapeGesture.pageSpace === overlay)
    }
}
