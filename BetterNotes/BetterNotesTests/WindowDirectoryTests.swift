import Foundation
import PencilKit
import Testing
@testable import BetterNotes

/// M9: one window reaching another (bring forward, pages dragged between windows).
@MainActor
struct WindowDirectoryTests {
    @Test func openingANotebookOpenElsewhereShowsItsTabThere() throws {
        let folder = try TempFolder()
        let first = try makeNotebook(in: folder.url, title: "First")
        let second = try makeNotebook(in: folder.url, title: "Second")
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(first)
        try windowOne.open(second)  // window one now shows "Second"

        #expect(throws: NotebookError.openInOtherWindow) { try windowTwo.open(NotebookPackage(url: first.url)) }
        #expect(windowOne.activeTab?.url == first.url)  // its tab is shown in window one
        #expect(windowTwo.tabs.isEmpty)
    }

    @Test func anOwnerWithoutAWindowIsStillRefused() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        #expect(registry.claim(package.url))  // a short claim, like a page transfer
        let window = WindowSession(registry: registry)
        #expect(throws: NotebookError.alreadyOpen) { try window.open(package) }
    }

    @Test func aPageDraggedFromAnotherWindowIsCopiedBeforeTheTarget() throws {
        let folder = try TempFolder()
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(try makeNotebook(in: folder.url, title: "Source"))
        try windowTwo.open(try makeNotebook(in: folder.url, title: "Target"))
        let source = try #require(windowOne.notebook), target = try #require(windowTwo.notebook)
        source.setDrawing(sampleDrawing(), for: source.pages[0].id)

        let actions = PageActions(notebook: target, navigator: PageNavigator(notebook: target), report: { Issue.record("\($0)") })
        let targetFirst = target.pages[0].id
        actions.drop(source.pages[0].id, selection: [], onto: targetFirst)

        #expect(target.pages.count == 2 && source.pages.count == 1)
        #expect(target.pages[1].id == targetFirst)
        #expect(target.pages[0].id != source.pages[0].id)  // a copy with its own id
        #expect(target.drawing(for: target.pages[0].id).strokes.count == 1)
        target.undoManager.undo()
        #expect(target.pages.count == 1)
    }
    @Test func aPageDroppedOnEmptySpaceGoesToTheEnd() throws {
        let folder = try TempFolder()
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(try makeNotebook(in: folder.url, title: "Source"))
        try windowTwo.open(try makeNotebook(in: folder.url, title: "Target"))
        let source = try #require(windowOne.notebook), target = try #require(windowTwo.notebook)
        try target.addPageAtEnd()
        let actions = PageActions(notebook: target, navigator: PageNavigator(notebook: target), report: { Issue.record("\($0)") })
        let firstOwn = target.pages[0].id

        actions.dropAtEnd(source.pages[0].id)  // from the other window: copied to the end
        #expect(target.pages.count == 3 && target.pages[0].id == firstOwn)
        #expect(target.drawing(for: target.pages[2].id).strokes.isEmpty && target.pages[2].id != source.pages[0].id)
        actions.dropAtEnd(firstOwn)  // our own page: moved to the end
        #expect(target.pages.last?.id == firstOwn)
    }

    @Test func aDroppedPageThatIsNowhereSaysSo() throws {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        var message: String?
        let actions = PageActions(notebook: notebook, navigator: PageNavigator(notebook: notebook), report: { message = $0 })
        actions.dropAtEnd(UUID())
        #expect(message != nil && notebook.pages.count == 1)
    }
}
