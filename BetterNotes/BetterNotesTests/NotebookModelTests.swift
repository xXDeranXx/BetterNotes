import Foundation
import PencilKit
import Testing
@testable import BetterNotes

@MainActor
struct NotebookModelTests {
    /// A notebook with `pageCount` lined pages, opened through the real file code.
    private func makeOpenNotebook(in folder: TempFolder, pageCount: Int = 1) throws -> Notebook {
        let package = try makeNotebook(in: folder.url)
        var meta = try package.readMeta()
        while meta.pages.count < pageCount {
            meta.pages.append(PageMeta(template: .lined, size: .a4Portrait))
        }
        try package.writeMeta(meta)
        return try Notebook.open(package)
    }

    @Test func openingReadsPagesFromMeta() throws {
        let folder = try TempFolder()

        let notebook = try makeOpenNotebook(in: folder, pageCount: 3)

        #expect(notebook.pages.count == 3)
        #expect(notebook.drawing(for: notebook.pages[0].id).strokes.isEmpty)
    }

    @Test func setDrawingStoresInkAndMarksThePageDirty() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id

        notebook.setDrawing(sampleDrawing(), for: page)

        #expect(notebook.drawing(for: page).strokes.count == 1)
        #expect(notebook.dirtyPageIDs == [page])
    }

    @Test func undoAndRedoRestoreTheDrawing() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id

        notebook.setDrawing(sampleDrawing(), for: page)
        notebook.undoManager.undo()
        #expect(notebook.drawing(for: page).strokes.isEmpty)
        #expect(notebook.undoManager.canRedo)

        notebook.undoManager.redo()
        // PKDrawing's == compares identity, so check the ink itself.
        let stroke = try #require(notebook.drawing(for: page).strokes.first)
        #expect(stroke.path.count == 2)
        #expect(stroke.path.last?.location == CGPoint(x: 100, y: 80))
        #expect(notebook.undoManager.canUndo)
    }

    @Test func oneHistoryRunsAcrossPagesNewestFirst() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let pageA = notebook.pages[0].id, pageB = notebook.pages[1].id
        notebook.setDrawing(sampleDrawing(offset: 0), for: pageA)
        notebook.setDrawing(sampleDrawing(offset: 5), for: pageB)

        notebook.undoManager.undo()
        #expect(notebook.drawing(for: pageB).strokes.isEmpty)
        #expect(notebook.drawing(for: pageA).strokes.count == 1)

        notebook.undoManager.undo()
        #expect(notebook.drawing(for: pageA).strokes.isEmpty)
    }

    @Test func undoStillWorksAfterTheCanvasWasDropped() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let page = notebook.pages[0].id
        var shownPages: [UUID] = []
        notebook.onDrawingChange = { shownPages.append($0) }
        notebook.setDrawing(sampleDrawing(), for: page)

        // The page scrolls off screen: its canvas is dropped and stops listening.
        notebook.onDrawingChange = nil
        notebook.setDrawing(sampleDrawing(offset: 3), for: notebook.pages[1].id)
        notebook.undoManager.undo()
        notebook.undoManager.undo()

        #expect(notebook.drawing(for: page).strokes.isEmpty)
        #expect(shownPages == [page])  // only the first change reached a listening canvas
    }

    @Test func aVisibleCanvasIsToldAboutUndoAndRedo() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        var told: [UUID] = []
        notebook.onDrawingChange = { told.append($0) }

        notebook.setDrawing(sampleDrawing(), for: page)
        notebook.undoManager.undo()
        notebook.undoManager.redo()

        #expect(told == [page, page, page])
    }

    @Test func anEditAfterUndoClearsRedo() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(offset: 0), for: page)
        notebook.undoManager.undo()

        notebook.setDrawing(sampleDrawing(offset: 9), for: page)

        #expect(!notebook.undoManager.canRedo)
    }

    @Test func settingTheSameDrawingIsNotAnUndoStep() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id

        // A canvas that echoes the model's own drawing back must not create a step.
        notebook.setDrawing(notebook.drawing(for: page), for: page)

        #expect(!notebook.undoManager.canUndo)
        #expect(notebook.dirtyPageIDs.isEmpty)
    }

    @Test func severalChangesInOneActionUndoTogether() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let pageA = notebook.pages[0].id, pageB = notebook.pages[1].id

        notebook.performUndoableChange("Two pages") {
            notebook.setDrawing(sampleDrawing(), for: pageA)
            notebook.setDrawing(sampleDrawing(), for: pageB)
        }
        notebook.undoManager.undo()

        #expect(notebook.drawing(for: pageA).strokes.isEmpty)
        #expect(notebook.drawing(for: pageB).strokes.isEmpty)
        #expect(!notebook.undoManager.canUndo)
    }

    @Test func undoStepsAreNamed() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)

        notebook.setDrawing(sampleDrawing(), for: notebook.pages[0].id)

        #expect(notebook.undoManager.undoActionName == "Draw")
    }

    @Test func inkIsLoadedLazilyFromDisk() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let page = try package.readMeta().pages[0].id
        try package.saveDrawing(sampleDrawing(), for: page)

        let notebook = try Notebook.open(package)

        #expect(notebook.drawing(for: page).strokes.count == 1)
        #expect(notebook.dirtyPageIDs.isEmpty)  // loading is not a change
    }

    @Test func anUnreadableDrawingIsReportedAndItsFileLeftAlone() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let page = try package.readMeta().pages[0].id
        let garbage = Data("not a drawing".utf8)
        try garbage.write(to: package.drawingURL(for: page))
        let notebook = try Notebook.open(package)

        #expect(notebook.drawing(for: page).strokes.isEmpty)

        #expect(notebook.unreadablePageIDs == [page])
        #expect(try Data(contentsOf: package.drawingURL(for: page)) == garbage)
    }

    @Test func windowsKeepSeparateSessionsAndHistories() throws {
        let folder = try TempFolder()
        let notebookOne = try makeNotebook(in: folder.url, title: "One")
        let notebookTwo = try makeNotebook(in: folder.url, title: "Two")
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)

        try windowOne.open(notebookOne)

        #expect(windowOne.notebook != nil)
        #expect(windowTwo.notebook == nil)
        try windowTwo.open(notebookTwo)
        #expect(windowOne.notebook?.undoManager !== windowTwo.notebook?.undoManager)
    }
}
