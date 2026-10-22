import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// A PDF whose pages say "P1", "P2", ... in real text, so tests can read the order of the
/// pages out of the PDF itself and not only out of `meta.json`.
func makeLabeledPDF(in folder: URL, name: String = "labeled.pdf", labels: [String]) throws -> URL {
    let url = folder.appending(path: name)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
    try renderer.writePDF(to: url) { context in
        for label in labels {
            context.beginPage()
            (label as NSString).draw(
                at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
        }
    }
    return url
}

@MainActor
struct PageOperationsTests {
    /// An imported notebook "P1" ... "Pn".
    private func makeOpenNotebook(in folder: TempFolder, pageCount: Int = 4) throws -> Notebook {
        let labels = (1...pageCount).map { "P\($0)" }
        let source = try makeLabeledPDF(in: folder.url, labels: labels)
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "Slides", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)  // tests save by hand
        return notebook
    }

    /// The text on each page of the notebook's PDF, in PDF order ("" for a page without text).
    private func labels(_ notebook: Notebook) -> [String] {
        let document = notebook.document!
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The rule everything here protects: page list and PDF have the same length and sizes.
    private func expectConsistent(_ notebook: Notebook, sourceLocation: SourceLocation = #_sourceLocation) {
        let document = notebook.document!
        #expect(document.pageCount == notebook.pages.count, sourceLocation: sourceLocation)
        for index in 0..<min(document.pageCount, notebook.pages.count) {
            let page = document.page(at: index)!
            let expected = NotebookPackage.pageMeta(of: page)
            #expect(notebook.pages[index].size == expected.size, sourceLocation: sourceLocation)
            #expect(notebook.pages[index].rotation == expected.rotation, sourceLocation: sourceLocation)
        }
        #expect(Set(notebook.pages.map(\.id)).count == notebook.pages.count, sourceLocation: sourceLocation)
    }

    // MARK: Add and insert

    @Test func addPageAtEndAppendsABlankPageOfTheLastPagesSize() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)

        let id = try notebook.addPageAtEnd()

        #expect(notebook.pages.count == 3 && notebook.pages[2].id == id)
        #expect(notebook.pages[2].template == .blank)  // after an imported page: blank
        #expect(notebook.pages[2].size == notebook.pages[1].size)
        #expect(labels(notebook) == ["P1", "P2", ""])
        expectConsistent(notebook)
    }

    @Test func insertingAPageUsesTheNeighborsSizeAndTheChosenTemplate() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 3)

        let id = try notebook.addPage(template: .grid, at: 1)

        #expect(notebook.pages.map(\.id)[1] == id)
        #expect(notebook.pages[1].template == .grid)
        #expect(labels(notebook) == ["P1", "", "P2", "P3"])
        expectConsistent(notebook)
    }

    @Test func insertingAtTheStartTakesTheFirstPagesSize() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)

        try notebook.addPage(template: .lined, at: 0)

        #expect(notebook.pages[0].template == .lined)
        #expect(notebook.pages[0].size == notebook.pages[1].size)
        expectConsistent(notebook)
    }

    @Test func undoAndRedoOfAddingAPage() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let before = notebook.pages

        try notebook.addPageAtEnd()
        notebook.undoManager.undo()
        #expect(notebook.pages == before)
        #expect(labels(notebook) == ["P1", "P2"])

        notebook.undoManager.redo()
        #expect(notebook.pages.count == 3)
        expectConsistent(notebook)
    }

    // MARK: Delete

    @Test func deletingPagesRemovesThemFromPDFAndListAndUndoBringsThemBackWithInk() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let before = notebook.pages
        notebook.setDrawing(sampleDrawing(), for: before[1].id)

        try notebook.deletePages([before[1].id, before[2].id])

        #expect(notebook.pages.map(\.id) == [before[0].id, before[3].id])
        #expect(labels(notebook) == ["P1", "P4"])
        expectConsistent(notebook)

        notebook.undoManager.undo()
        #expect(notebook.pages == before)  // same ids, same order
        #expect(labels(notebook) == ["P1", "P2", "P3", "P4"])
        #expect(notebook.drawing(for: before[1].id).strokes.count == 1)  // the ink is back with its page
        expectConsistent(notebook)
    }

    @Test func theLastPageCannotBeDeleted() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)

        #expect(throws: NotebookError.cannotDeleteAllPages) {
            try notebook.deletePages(Set(notebook.pages.map(\.id)))
        }
        #expect(notebook.pages.count == 2)
        expectConsistent(notebook)
    }

    @Test func deletedInkStaysOnDisk() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let doomed = notebook.pages[1].id
        notebook.setDrawing(sampleDrawing(), for: doomed)
        await notebook.saveChanges()

        try notebook.deletePages([doomed])
        await notebook.saveChanges()

        // SPEC, "Data safety": no code path deletes user files.
        #expect(FileManager.default.fileExists(atPath: notebook.package.drawingURL(for: doomed).path))
    }

    // MARK: Duplicate

    @Test func duplicatingCopiesThePageAndItsInkRightAfterTheOriginal() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 3)
        let original = notebook.pages[1].id
        notebook.setDrawing(sampleDrawing(), for: original)

        let copies = try notebook.duplicatePages([original])

        #expect(copies.count == 1 && copies[0] != original)
        #expect(notebook.pages.map(\.id)[2] == copies[0])
        #expect(labels(notebook) == ["P1", "P2", "P2", "P3"])
        #expect(notebook.drawing(for: copies[0]).strokes.count == 1)
        #expect(notebook.drawing(for: original).strokes.count == 1)
        expectConsistent(notebook)

        notebook.undoManager.undo()
        #expect(labels(notebook) == ["P1", "P2", "P3"])
    }

    @Test func duplicatingSeveralPagesKeepsEachCopyNextToItsOriginal() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 4)

        try notebook.duplicatePages([notebook.pages[0].id, notebook.pages[2].id])

        #expect(labels(notebook) == ["P1", "P1", "P2", "P3", "P3", "P4"])
        expectConsistent(notebook)
    }

    // MARK: Move

    @Test func movingPagesReordersPDFAndListAndKeepsInkOnItsPage() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let first = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: first)
        let before = notebook.pages

        try notebook.movePages([first], toIndex: 3)  // to the very end

        #expect(labels(notebook) == ["P2", "P3", "P4", "P1"])
        #expect(notebook.pages.last?.id == first)
        #expect(notebook.drawing(for: first).strokes.count == 1)  // ink follows its page id
        expectConsistent(notebook)

        notebook.undoManager.undo()
        #expect(notebook.pages == before)
        #expect(labels(notebook) == ["P1", "P2", "P3", "P4"])
    }

    @Test func movingSeveralPagesKeepsTheirOrderAmongThemselves() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 5)
        let ids = notebook.pages.map(\.id)

        try notebook.movePages([ids[3], ids[1]], toIndex: 0)  // P2 and P4 to the front

        #expect(labels(notebook) == ["P2", "P4", "P1", "P3", "P5"])
        expectConsistent(notebook)
    }

    @Test func movingToTheSamePlaceDoesNothingAndRegistersNoUndoStep() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let ids = notebook.pages.map(\.id)

        try notebook.movePages([ids[1]], toIndex: 1)

        #expect(labels(notebook) == ["P1", "P2", "P3", "P4"])
        #expect(!notebook.undoManager.canUndo)
    }

    // MARK: Rotate

    @Test func rotatingTurnsThePDFPageAndSwapsTheStoredSize() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let id = notebook.pages[0].id

        try notebook.rotatePages([id], by: 90)

        #expect(notebook.pages[0].rotation == 90)
        #expect(notebook.pages[0].size == PageSize(width: 842, height: 595))
        #expect(notebook.document?.page(at: 0)?.rotation == 90)
        #expect(notebook.pages[1].rotation == 0)
        expectConsistent(notebook)

        notebook.undoManager.undo()
        #expect(notebook.pages[0].rotation == 0)
        #expect(notebook.pages[0].size == PageSize(width: 595, height: 842))
        expectConsistent(notebook)
    }

    @Test func rotatingCounterClockwiseAndFourTimesComesBack() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 1)
        let id = notebook.pages[0].id

        try notebook.rotatePages([id], by: -90)
        #expect(notebook.pages[0].rotation == 270)

        for _ in 0..<3 { try notebook.rotatePages([id], by: 90) }
        #expect(notebook.pages[0].rotation == 180)
        try notebook.rotatePages([id], by: 180)
        #expect(notebook.pages[0].rotation == 0)
        #expect(notebook.pages[0].size == PageSize(width: 595, height: 842))
        expectConsistent(notebook)
    }

    // MARK: Pages from elsewhere

    @Test func insertingPagesFromAnotherPDFKeepsTheirContentAndOrder() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let other = try makeLabeledPDF(in: folder.url, name: "other.pdf", labels: ["A", "B", "C"])
        let entries = try Notebook.makeEntries(from: try #require(PDFDocument(url: other)), pageIndexes: [0, 2])

        let ids = try notebook.insertPages(entries, at: 1)

        #expect(ids.count == 2)
        #expect(labels(notebook) == ["P1", "A", "C", "P2"])
        #expect(notebook.pages[1].template == .pdf)
        expectConsistent(notebook)

        notebook.undoManager.undo()
        #expect(labels(notebook) == ["P1", "P2"])
    }

    @Test func anImageBecomesAPageAsWideAsA4AndAsTallAsItNeeds() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 600)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        }

        let entry = try Notebook.makeImagePage(from: image.pngData()!)
        try notebook.insertPages([entry], at: 1)

        #expect(notebook.pages[1].size == PageSize(width: 595, height: 1190))
        #expect(notebook.pages[1].template == .pdf)
        expectConsistent(notebook)
    }

    @Test func somethingThatIsNotAnImageIsRefused() {
        #expect(throws: NotebookError.imageUnreadable) {
            try Notebook.makeImagePage(from: Data("nope".utf8))
        }
    }

    @Test func aLargePhotoDoesNotMakeAHugePDF() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { context in
            for i in 0..<400 {  // some detail so it is not trivially compressible
                UIColor(hue: CGFloat(i % 50) / 50, saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: (i * 97) % 3900, y: (i * 61) % 2900, width: 120, height: 90))
            }
        }

        let entry = try Notebook.makeImagePage(from: image.jpegData(compressionQuality: 0.9)!)
        let document = PDFDocument()
        document.insert(entry.pdfPage, at: 0)

        #expect((document.dataRepresentation()?.count ?? .max) < 4_000_000)
    }

    // MARK: Undo as a whole

    @Test func aMixOfOperationsCanBeUndoneBackToTheExactStartAndRedone() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 4)
        let start = notebook.pages
        notebook.setDrawing(sampleDrawing(), for: start[2].id)
        notebook.undoManager.removeAllActions()

        try notebook.addPage(template: .dotted, at: 2)
        try notebook.movePages([start[0].id], toIndex: 4)
        try notebook.rotatePages([start[1].id], by: 90)
        try notebook.duplicatePages([start[2].id])
        try notebook.deletePages([start[3].id])
        let end = notebook.pages
        let endLabels = labels(notebook)

        while notebook.undoManager.canUndo { notebook.undoManager.undo() }
        #expect(notebook.pages == start)
        #expect(labels(notebook) == ["P1", "P2", "P3", "P4"])
        #expect(notebook.drawing(for: start[2].id).strokes.count == 1)
        expectConsistent(notebook)

        while notebook.undoManager.canRedo { notebook.undoManager.redo() }
        #expect(notebook.pages == end)
        #expect(labels(notebook) == endLabels)
        expectConsistent(notebook)
    }

    @Test func pageOperationsTellTheEditorToRefresh() throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        var calls = 0
        notebook.onStructureChange = { calls += 1 }

        try notebook.addPageAtEnd()
        notebook.undoManager.undo()

        #expect(calls == 2)
    }

    @Test func aNotebookWhoseListAndPDFDisagreeRefusesPageOperations() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var meta = try package.readMeta()
        meta.pages.append(PageMeta(template: .lined, size: .a4Portrait))  // two entries, one PDF page
        try package.writeMeta(meta)

        let notebook = try Notebook.open(package)

        #expect(notebook.document == nil && notebook.structureProblem != nil)
        #expect(throws: NotebookError.pagesCannotBeChanged) { try notebook.addPageAtEnd() }
    }

    // MARK: Saving

    @Test func pageChangesAreSavedAndSurviveReopening() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 3)
        let ids = notebook.pages.map(\.id)
        notebook.setDrawing(sampleDrawing(), for: ids[0])
        try notebook.movePages([ids[0]], toIndex: 2)  // P2 P3 P1
        try notebook.rotatePages([ids[2]], by: 90)
        let newID = try notebook.addPage(template: .lined, at: 1)
        #expect(notebook.hasUnsavedChanges)

        await notebook.saveChanges()

        #expect(!notebook.hasUnsavedChanges && notebook.saveError == nil)
        let reopened = try Notebook.open(notebook.package)  // like force-quit and relaunch
        #expect(reopened.document != nil, "the page list and the PDF must agree after reopening")
        #expect(reopened.pages == notebook.pages)
        #expect(labels(reopened) == ["P2", "", "P3", "P1"])
        #expect(reopened.pages[1].id == newID)
        #expect(reopened.drawing(for: ids[0]).strokes.count == 1)  // ink is still on P1
        expectConsistent(reopened)
    }

    @Test func pagesInsertedFromAnotherPDFSurviveSavingAfterTheSourceIsGone() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        let other = try makeLabeledPDF(in: folder.url, name: "other.pdf", labels: ["A", "B"])
        // The app reads the file into memory and lets the source document go (see PageActions).
        func insertAndLetTheSourceGo() throws {
            let source = try #require(PDFDocument(data: try Data(contentsOf: other)))
            try notebook.insertPages(try Notebook.makeEntries(from: source), at: 1)
        }
        try insertAndLetTheSourceGo()
        try FileManager.default.removeItem(at: other)  // not even the file is left

        await notebook.saveChanges()

        let reopened = try Notebook.open(notebook.package)
        #expect(labels(reopened) == ["P1", "A", "B", "P2"])
        expectConsistent(reopened)
    }

    @Test func aFailedPageSaveKeepsTheOldFilesMatchingAndTheChangePending() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        try notebook.addPageAtEnd()
        let package = notebook.package

        // Make the notebook folder read-only so nothing can be written into it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        await notebook.saveChanges()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path)

        #expect(notebook.saveError != nil)
        #expect(notebook.structureDirty && notebook.hasUnsavedChanges)  // closing is refused
        let onDisk = try Notebook.open(package)  // the old pair, still matching
        #expect(onDisk.document != nil && onDisk.pages.count == 2)

        await notebook.saveChanges()  // after the problem is fixed, Retry works
        #expect(notebook.saveError == nil && !notebook.structureDirty)
        #expect(try Notebook.open(package).pages.count == 3)
    }

    @Test func aChangeDuringASaveIsNotMarkedAsSaved() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)
        try notebook.addPageAtEnd()
        notebook.saveHook = { [notebook] in
            await MainActor.run { _ = try? notebook.addPageAtEnd() }  // changes while the save runs
        }

        await notebook.saveChanges()
        notebook.saveHook = nil

        #expect(notebook.structureDirty)  // the second page is not on disk yet
        await notebook.saveChanges()
        #expect(!notebook.structureDirty)
        #expect(try Notebook.open(notebook.package).pages.count == 4)
    }
}

/// The two-file commit (`document.pdf` + `meta.json`) after a crash at each possible point.
@MainActor
struct StructureCommitTests {
    /// A notebook "before" (2 pages) and the "after" pair (3 pages) the commit would write.
    private func makeScenario(in folder: TempFolder) throws -> (package: NotebookPackage, newPDF: Data, newMeta: NotebookMeta) {
        let source = try makeLabeledPDF(in: folder.url, labels: ["P1", "P2"])
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "T", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        try notebook.addPageAtEnd()
        return (package, notebook.document!.dataRepresentation()!, notebook.meta)
    }

    @Test func aCrashBeforeTheCommitMarkerKeepsTheOldPair() throws {
        let folder = try TempFolder()
        let (package, pdf, meta) = try makeScenario(in: folder)
        try package.stageStructure(pdfData: pdf, meta: meta)
        try FileManager.default.removeItem(at: package.url.appending(path: "pending/COMMIT"))  // died before the marker

        let reopened = try Notebook.open(package)

        #expect(reopened.pages.count == 2 && reopened.document?.pageCount == 2)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "pending").path))
    }

    @Test func aCrashAfterTheMarkerFinishesTheNewPairOnReopening() throws {
        let folder = try TempFolder()
        let (package, pdf, meta) = try makeScenario(in: folder)
        try package.stageStructure(pdfData: pdf, meta: meta)  // nothing moved yet

        let reopened = try Notebook.open(package)

        #expect(reopened.pages.count == 3 && reopened.document?.pageCount == 3)
    }

    @Test func aCrashBetweenTheTwoMovesStillEndsWithAMatchingPair() throws {
        let folder = try TempFolder()
        let (package, pdf, meta) = try makeScenario(in: folder)
        try package.stageStructure(pdfData: pdf, meta: meta)
        // Simulate: document.pdf was already moved into place, meta.json was not.
        _ = try FileManager.default.replaceItemAt(
            package.pdfURL, withItemAt: package.url.appending(path: "pending/document.pdf"))
        #expect(try package.readMeta().pages.count == 2)  // the mismatch a crash would leave

        let reopened = try Notebook.open(package)

        #expect(reopened.pages.count == 3 && reopened.document?.pageCount == 3)
    }

    @Test func afterACompletedCommitNothingIsLeftBehind() throws {
        let folder = try TempFolder()
        let (package, pdf, meta) = try makeScenario(in: folder)

        try package.commitStructure(pdfData: pdf, meta: meta)

        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "pending").path))
        #expect(try package.readMeta().pages.count == 3)
    }
}
