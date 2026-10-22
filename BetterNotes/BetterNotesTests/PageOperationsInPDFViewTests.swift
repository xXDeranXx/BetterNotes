import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Page operations against a real `PDFView` with canvases on screen. The model tests prove
/// the data is right; these prove the editor still shows each page's own ink afterwards
/// (the M2 lesson: green model tests can hide a broken editor).
@MainActor
struct PageOperationsInPDFViewTests {
    /// A notebook "P1".."P3" with a different stroke on every page, shown in a real PDFView.
    private struct Setup {
        let notebook: Notebook
        let coordinator: EditorCoordinator
        let pdfView: PDFView
        let window: UIWindow
        let folder: TempFolder
    }

    private func makeSetup() async throws -> Setup {
        let folder = try TempFolder()
        let source = try makeLabeledPDF(in: folder.url, labels: ["P1", "P2", "P3"])
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "T", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)
        for (index, page) in notebook.pages.enumerated() {
            notebook.setDrawing(lineDrawing(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200 + CGFloat(index) * 100, y: 100)), for: page.id)
        }
        let coordinator = EditorCoordinator(notebook: notebook)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        let pdfView = PDFView(frame: window.bounds)
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.pageOverlayViewProvider = coordinator
        pdfView.document = notebook.document
        window.addSubview(pdfView)
        window.makeKeyAndVisible()
        notebook.onStructureChange = { [weak pdfView] in pdfView?.layoutDocumentView() }
        let setup = Setup(notebook: notebook, coordinator: coordinator, pdfView: pdfView, window: window, folder: folder)
        try await settle(setup)
        return setup
    }

    private func settle(_ setup: Setup) async throws {
        setup.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        setup.window.layoutIfNeeded()
    }

    /// Every visible overlay must belong to the page PDFKit shows at its position, and its
    /// canvas must hold that page's drawing.
    private func expectEveryCanvasShowsItsOwnPage(_ setup: Setup, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!setup.coordinator.visibleOverlays.isEmpty, sourceLocation: sourceLocation)
        for overlay in setup.coordinator.visibleOverlays.values {
            let center = setup.pdfView.convert(CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), from: overlay)
            let shownPage = setup.pdfView.page(for: center, nearest: false)
            #expect(shownPage != nil, sourceLocation: sourceLocation)
            guard let shownPage else { continue }
            #expect(setup.coordinator.pageID(for: shownPage) == overlay.pageID, sourceLocation: sourceLocation)
            let model = setup.notebook.drawing(for: overlay.pageID)
            #expect(overlay.canvas.drawing.strokes.count == model.strokes.count, sourceLocation: sourceLocation)
            #expect(overlay.canvas.drawing.bounds == model.bounds, sourceLocation: sourceLocation)
        }
    }

    @Test func insertingAPageAtTheStartKeepsEveryCanvasOnItsOwnPage() async throws {
        let setup = try await makeSetup()
        expectEveryCanvasShowsItsOwnPage(setup)

        try setup.notebook.addPage(template: .lined, at: 0)
        try await settle(setup)

        expectEveryCanvasShowsItsOwnPage(setup)
        #expect(setup.pdfView.document?.pageCount == 4)
    }

    @Test func deletingAndUndoingKeepsEveryCanvasOnItsOwnPage() async throws {
        let setup = try await makeSetup()
        let first = setup.notebook.pages[0].id

        try setup.notebook.deletePages([first])
        try await settle(setup)
        expectEveryCanvasShowsItsOwnPage(setup)
        #expect(setup.coordinator.visibleOverlays[first] == nil)

        setup.notebook.undoManager.undo()
        try await settle(setup)
        expectEveryCanvasShowsItsOwnPage(setup)
        #expect(setup.coordinator.visibleOverlays[first] != nil)
    }

    @Test func reorderingKeepsEveryCanvasOnItsOwnPage() async throws {
        let setup = try await makeSetup()

        try setup.notebook.movePages([setup.notebook.pages[0].id], toIndex: 2)
        try await settle(setup)

        expectEveryCanvasShowsItsOwnPage(setup)
    }

    @Test func rotatingTurnsTheVisibleCanvasWithItsPage() async throws {
        let setup = try await makeSetup()
        let id = setup.notebook.pages[0].id
        let overlay = try #require(setup.coordinator.visibleOverlays[id])
        let widthBefore = setup.pdfView.convert(CGPoint(x: overlay.bounds.maxX, y: 0), from: overlay).x
            - setup.pdfView.convert(CGPoint.zero, from: overlay).x
        #expect(widthBefore > 0)  // the overlay's x axis runs left to right

        try setup.notebook.rotatePages([id], by: 90)
        try await settle(setup)

        // After a turn by 90 the overlay's x axis runs top to bottom on screen.
        let turned = try #require(setup.coordinator.visibleOverlays[id])
        let origin = setup.pdfView.convert(CGPoint.zero, from: turned)
        let xAxisEnd = setup.pdfView.convert(CGPoint(x: turned.bounds.maxX, y: 0), from: turned)
        #expect(abs(xAxisEnd.x - origin.x) < 1 && xAxisEnd.y - origin.y > 100)
        expectEveryCanvasShowsItsOwnPage(setup)
    }
}
