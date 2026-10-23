import PDFKit
import Testing
import UIKit
@testable import BetterNotes

/// Horizontal page-by-page mode with the real editor on screen. PDFKit's page view controller
/// keeps showing a page after it was deleted or moved, so the editor reloads it after every page
/// operation; these tests check that the right page and only its canvas are shown.
@MainActor
struct PageByPageTests {
    @MainActor private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let navigator: PageNavigator
        let controller: NotebookEditorViewController
        let window: UIWindow

        /// The overlays the editor knows about. Each must be on screen.
        var overlays: [PageOverlayView] { Array(controller.coordinatorForTests.visibleOverlays.values) }

        /// The index of the page whose canvas is on screen (page by page there is one).
        var shownIndex: Int? {
            let shown = overlays.filter { $0.window != nil }
            guard shown.count == 1 else { return nil }
            return notebook.pages.firstIndex { $0.id == shown[0].pageID }
        }

        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
        }
    }

    private func makeSetup(pages: Int = 4, horizontal: Bool = true) async throws -> Setup {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        for _ in 1..<pages { _ = try notebook.addPageAtEnd() }
        notebook.undoManager.removeAllActions()
        let navigator = PageNavigator(notebook: notebook)
        let controller = NotebookEditorViewController(notebook: notebook, search: DocumentSearch(), navigator: navigator)
        controller.scrollsHorizontally = horizontal
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let setup = Setup(folder: folder, notebook: notebook, navigator: navigator, controller: controller, window: window)
        try await setup.settle()
        return setup
    }

    private func pdfView(in setup: Setup) throws -> PDFView {
        try #require(setup.controller.view.subviews.compactMap { $0 as? PDFView }.first)
    }

    @Test func showsOneWholePageAtATime() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        #expect(setup.shownIndex == 0)
        #expect(setup.overlays.count == 1)
        // The whole page fits: its overlay lies inside the editor.
        let overlay = try #require(setup.overlays.first)
        let frame = overlay.convert(overlay.bounds, to: setup.controller.view)
        #expect(setup.controller.view.bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }

    @Test func goingToAPageShowsIt() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        setup.navigator.goTo(setup.notebook.pages[2].id)
        try await setup.settle()
        #expect(setup.shownIndex == 2)
        #expect(setup.navigator.currentPageID == setup.notebook.pages[2].id)
    }

    @Test func deletingTheShownPageShowsTheNextOneAndUndoKeepsIt() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        setup.navigator.goTo(setup.notebook.pages[1].id)
        try await setup.settle()
        let next = setup.notebook.pages[2].id

        try setup.notebook.deletePages([setup.notebook.pages[1].id])
        try await setup.settle()
        #expect(setup.shownIndex == 1)
        #expect(setup.overlays.allSatisfy { $0.window != nil && $0.pageID == next })
        #expect(setup.navigator.currentPageID == next)  // the sidebar highlight follows

        setup.notebook.undoManager.undo()  // the page comes back; the shown page stays
        try await setup.settle()
        #expect(setup.notebook.pages.count == 4)
        #expect(setup.shownIndex == 2)
        #expect(setup.overlays.allSatisfy { $0.window != nil })
    }

    @Test func deletingTheLastPageShowsTheNewLastPage() async throws {
        let setup = try await makeSetup(pages: 3)
        defer { setup.window.isHidden = true }
        setup.navigator.goTo(setup.notebook.pages[2].id)
        try await setup.settle()
        try setup.notebook.deletePages([setup.notebook.pages[2].id])
        try await setup.settle()
        #expect(setup.shownIndex == 1)
    }

    @Test func pagesAddedOrMovedBeforeTheShownPageKeepItOnScreen() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        let shown = setup.notebook.pages[2].id
        setup.navigator.goTo(shown)
        try await setup.settle()

        let copies = try setup.notebook.duplicatePages([setup.notebook.pages[0].id])
        try await setup.settle()
        #expect(setup.shownIndex == 3)
        #expect(setup.overlays.allSatisfy { $0.window != nil && $0.pageID == shown })

        try setup.notebook.movePages([shown], toIndex: 0)
        try await setup.settle()
        #expect(setup.shownIndex == 0)

        // PDFKit used to think it was already on the copy and ignored the jump.
        setup.navigator.goTo(copies[0])
        try await setup.settle()
        #expect(setup.overlays.allSatisfy { $0.window != nil && $0.pageID == copies[0] })
    }

    @Test func switchingDirectionKeepsThePageAndDropsOldCanvases() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        setup.navigator.goTo(setup.notebook.pages[2].id)
        try await setup.settle()

        setup.controller.scrollsHorizontally = false
        try await setup.settle()
        #expect(setup.overlays.allSatisfy { $0.window != nil })
        // PDFView's current page (the top-left corner can be in the gap above it).
        let pdf = try pdfView(in: setup)
        #expect(pdf.currentPage.flatMap { setup.notebook.pageID(for: $0) } == setup.notebook.pages[2].id)

        setup.controller.scrollsHorizontally = true
        try await setup.settle()
        #expect(setup.shownIndex == 2)
    }

    /// The touch types the paging scroll view's swipe takes.
    private func pageTurnTouchTypes(in setup: Setup) throws -> [Int] {
        var queue: [UIView] = [try pdfView(in: setup)]
        var pager: UIScrollView?
        while let view = queue.first, pager == nil {
            queue.removeFirst()
            if let scroll = view as? UIScrollView, scroll.isPagingEnabled { pager = scroll }
            queue.append(contentsOf: view.subviews)
        }
        return try #require(pager).panGestureRecognizer.allowedTouchTypes.map(\.intValue)
    }

    @Test func thePencilDoesNotTurnPagesAlsoAfterAReload() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        func check() throws {
            let types = try pageTurnTouchTypes(in: setup)
            #expect(types.contains(UITouch.TouchType.direct.rawValue))
            #expect(!types.contains(UITouch.TouchType.pencil.rawValue))
        }
        try check()
        // A page operation and a mode switch each make a new page view controller.
        try setup.notebook.deletePages([setup.notebook.pages[0].id])
        try await setup.settle()
        try check()
        setup.controller.scrollsHorizontally = false
        try await setup.settle()
        setup.controller.scrollsHorizontally = true
        try await setup.settle()
        try check()
    }

    @Test func aNewPageIsShownRightAfterInsertingIt() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        // Like the "+" button: insert after the shown page and jump there in the same turn.
        let added = try setup.notebook.addPage(template: .lined, at: 1)
        setup.navigator.goTo(added)
        try await setup.settle()
        #expect(setup.shownIndex == 1)
        #expect(setup.navigator.currentPageID == added)
    }

    @Test func aTabSavedPageByPageOpensAtThatPageInTheColumn() async throws {
        let setup = try await makeSetup()
        defer { setup.window.isHidden = true }
        setup.navigator.goTo(setup.notebook.pages[3].id)
        try await setup.settle()
        let position = try #require(setup.controller.currentPosition())
        #expect(position.pageID == setup.notebook.pages[3].id && position.zoom == 0)

        // A new editor (relaunch) in the vertical column goes back to that page at its fit.
        let vertical = NotebookEditorViewController(
            notebook: setup.notebook, search: DocumentSearch(), navigator: PageNavigator(notebook: setup.notebook))
        vertical.pendingPosition = position
        setup.window.rootViewController = vertical
        try await setup.settle()
        let pdf = try #require(vertical.view.subviews.compactMap { $0 as? PDFView }.first)
        #expect(pdf.currentPage.flatMap { setup.notebook.pageID(for: $0) } == setup.notebook.pages[3].id)
        #expect(abs(pdf.scaleFactor - pdf.scaleFactorForSizeToFit) < 0.01)
    }
}
