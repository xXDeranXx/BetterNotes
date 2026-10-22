import Foundation
import PencilKit
import Testing
@testable import BetterNotes

@MainActor
struct DrawingEvictionTests {
    /// An imported 4-page PDF notebook, opened through the real file code.
    private func makeOpenNotebook(in folder: TempFolder) throws -> Notebook {
        let source = try makeSamplePDF(in: folder.url, pageCount: 4)
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "Slides", coverColor: "#000000")
        return try Notebook.open(package)
    }

    @Test func savedOffscreenDrawingsAreDroppedAndLoadAgainUnchanged() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)
        await notebook.saveChanges()
        let before = notebook.drawing(for: page)

        notebook.evictDrawings(keeping: [])
        #expect(notebook.loadedPageIDs.isEmpty)

        // Compared by content: PencilKit's serialized bytes are not guaranteed to be identical.
        let after = notebook.drawing(for: page)
        #expect(after.strokes.count == before.strokes.count)
        #expect(after.bounds == before.bounds)
        #expect(after.strokes[0].path.map(\.location) == before.strokes[0].path.map(\.location))
    }

    @Test func unsavedDrawingsAreNeverDropped() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)  // dirty: not on disk yet

        notebook.evictDrawings(keeping: [])

        #expect(notebook.loadedPageIDs == [page])
        #expect(notebook.drawing(for: page).strokes.count == 1)
    }

    @Test func drawingsOnScreenAreKept() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let onScreen = notebook.pages[1].id
        _ = notebook.drawing(for: notebook.pages[0].id)
        _ = notebook.drawing(for: onScreen)

        notebook.evictDrawings(keeping: [onScreen])

        #expect(notebook.loadedPageIDs == [onScreen])
    }

    @Test func aDrawingFileThatCouldNotBeReadIsNotDropped() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        try Data("garbage".utf8).write(to: notebook.package.drawingURL(for: page))
        _ = notebook.drawing(for: page)  // fails to read, remembered as unreadable

        notebook.evictDrawings(keeping: [])

        #expect(notebook.unreadablePageIDs == [page])
        #expect(notebook.loadedPageIDs == [page])
    }

    @Test func undoStillWorksOnAPageWhoseDrawingWasDropped() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)
        await notebook.saveChanges()
        notebook.evictDrawings(keeping: [])

        notebook.undoManager.undo()
        #expect(notebook.drawing(for: page).strokes.isEmpty)

        notebook.undoManager.redo()
        #expect(notebook.drawing(for: page).strokes.count == 1)
    }

    @Test func scrollingThroughManyPagesDoesNotKeepAllDrawings() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        for page in notebook.pages {
            notebook.setDrawing(sampleDrawing(), for: page.id)
        }
        await notebook.saveChanges()

        // Pretend only the last page is on screen.
        notebook.evictDrawings(keeping: [notebook.pages[3].id])

        #expect(notebook.loadedPageIDs == [notebook.pages[3].id])
        // Everything is still there when scrolled back to.
        #expect(notebook.pages.allSatisfy { notebook.drawing(for: $0.id).strokes.count == 1 })
    }
}
