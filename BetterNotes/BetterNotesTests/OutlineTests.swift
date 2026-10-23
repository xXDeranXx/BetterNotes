import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// A PDF like lecture slides: each page has a large title and smaller body text.
/// A `nil` title makes a page with body text only.
func makeSlidesPDF(in folder: URL, titles: [String?], name: String = "slides.pdf") throws -> URL {
    let url = folder.appending(path: name)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595))
    try renderer.writePDF(to: url) { context in
        for title in titles {
            context.beginPage()
            if let title {
                NSAttributedString(string: title, attributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
                    .draw(at: CGPoint(x: 40, y: 40))
            }
            let body = "First point of this slide\nSecond point with more words\n3"
            NSAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: 16)])
                .draw(in: CGRect(x: 40, y: 120, width: 700, height: 300))
        }
    }
    return url
}

struct OutlineOrderTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func entriesAreShownInPageOrderAndMissingPagesAreHidden() {
        let entries = [
            OutlineEntry(title: "On C", pageID: c), OutlineEntry(title: "On A", pageID: a),
            OutlineEntry(title: "Gone", pageID: UUID()), OutlineEntry(title: "Also A", pageID: a),
        ]
        let shown = Outline.visible(entries, pageIDs: [a, b, c])
        #expect(shown.map(\.title) == ["On A", "Also A", "On C"])
    }

    @Test func levelsAreAtMostOneDeeperThanTheEntryBefore() {
        let entries = [
            OutlineEntry(title: "Deep first", pageID: a, level: 3),
            OutlineEntry(title: "Deeper", pageID: b, level: 5),
        ]
        #expect(Outline.visible(entries, pageIDs: [a, b]).map(\.level) == [0, 1])
    }

    @Test func treeNestsByLevelAndUsesPositionsOfTheGivenPages() {
        let entries = [
            OutlineEntry(title: "Chapter 1", pageID: a), OutlineEntry(title: "1.1", pageID: b, level: 1),
            OutlineEntry(title: "Chapter 2", pageID: c),
        ]
        let tree = Outline.tree(entries, pageIDs: [a, b, c])
        #expect(tree == [
            OutlineNode(title: "Chapter 1", pageIndex: 0, children: [OutlineNode(title: "1.1", pageIndex: 1)]),
            OutlineNode(title: "Chapter 2", pageIndex: 2),
        ])
        // An export of pages a and c only: 1.1 is left out, the page index follows the export.
        #expect(Outline.tree(entries, pageIDs: [a, c]) == [
            OutlineNode(title: "Chapter 1", pageIndex: 0), OutlineNode(title: "Chapter 2", pageIndex: 1),
        ])
    }

    @Test func currentEntryIsTheLastOneAtOrBeforeThePageOnScreen() {
        let entries = Outline.visible(
            [OutlineEntry(title: "A", pageID: a), OutlineEntry(title: "C", pageID: c)], pageIDs: [a, b, c])
        #expect(Outline.current(in: entries, pageIDs: [a, b, c], currentPageID: b) == entries[0].id)
        #expect(Outline.current(in: entries, pageIDs: [a, b, c], currentPageID: c) == entries[1].id)
    }

    @Test func collapsingHidesTheEntriesBelow() {
        let entries = Outline.visible([
            OutlineEntry(title: "1", pageID: a), OutlineEntry(title: "1.1", pageID: a, level: 1),
            OutlineEntry(title: "1.1.1", pageID: b, level: 2), OutlineEntry(title: "2", pageID: c),
        ], pageIDs: [a, b, c])
        #expect(Outline.hasChildren(at: 0, in: entries) && !Outline.hasChildren(at: 3, in: entries))
        let hidden = Outline.hiddenByCollapse(entries, collapsed: [entries[0].id])
        #expect(hidden == [entries[1].id, entries[2].id])
    }
}

struct OutlinePDFTests {
    @Test func bookmarksSurviveWritingAndReadingAPDF() throws {
        let folder = try TempFolder()
        let source = PDFDocument(url: try makeSamplePDF(in: folder.url, pageCount: 3))!
        let document = PDFDocument()
        for index in 0..<3 { document.insert(source.page(at: index)!.copy() as! PDFPage, at: index) }
        let nodes = [OutlineNode(title: "Intro", pageIndex: 0, children: [OutlineNode(title: "Detail", pageIndex: 1)]),
                     OutlineNode(title: "End", pageIndex: 2)]
        Outline.writeBookmarks(nodes, into: document)
        let url = folder.url.appending(path: "out.pdf")
        #expect(document.write(to: url))

        let ids = [UUID(), UUID(), UUID()]
        let reread = PDFDocument(url: url)!
        let entries = Outline.entries(fromBookmarksOf: reread, pageIDs: ids)
        #expect(entries.map(\.title) == ["Intro", "Detail", "End"])
        #expect(entries.map(\.pageID) == ids)
        #expect(entries.map(\.level) == [0, 1, 0])
    }

    @Test func slideTitlesAreGuessedFromTheLargestText() throws {
        let folder = try TempFolder()
        let url = try makeSlidesPDF(in: folder.url, titles: ["Linear Maps", "Linear Maps", nil, "Eigenvalues"])
        let ids = (0..<4).map { _ in UUID() }
        let entries = Outline.entries(guessedFrom: PDFDocument(url: url)!, pageIDs: ids)
        // The repeated title (a continued slide) and the page without a title are left out.
        #expect(entries.map(\.title) == ["Linear Maps", "Eigenvalues"])
        #expect(entries.map(\.pageID) == [ids[0], ids[3]])
    }

    @Test func pagesWithoutTextGiveNoOutline() throws {
        let folder = try TempFolder()
        let document = PDFDocument(url: try makeSamplePDF(in: folder.url, pageCount: 2))!
        #expect(Outline.entries(guessedFrom: document, pageIDs: [UUID(), UUID()]).isEmpty)
    }

    @Test func titlesAreOneShortLine() {
        #expect(Outline.clean("  Two\n lines ") == "Two lines")
        #expect(Outline.clean(String(repeating: "x", count: 150)).count == 100)
    }
}

@MainActor
struct NotebookOutlineTests {
    private func openNotebook(_ folder: TempFolder, pages: Int = 3) throws -> Notebook {
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        for _ in 1..<pages { try notebook.addPageAtEnd() }
        notebook.undoManager.removeAllActions()
        return notebook
    }

    @Test func addRenameIndentDeleteAreEachOneUndoStep() throws {
        let folder = try TempFolder()
        let notebook = try openNotebook(folder)
        let pages = notebook.pages.map(\.id)
        notebook.setUpOutline([])
        let first = try #require(notebook.addOutlineEntry(title: "Chapter", pageID: pages[0]))
        let second = try #require(notebook.addOutlineEntry(title: "Section", pageID: pages[1]))
        notebook.indentOutlineEntry(second, by: 1)
        notebook.renameOutlineEntry(first, to: "Chapter 1")
        #expect(notebook.visibleOutline.map(\.title) == ["Chapter 1", "Section"])
        #expect(notebook.visibleOutline.map(\.level) == [0, 1])

        notebook.indentOutlineEntry(second, by: 1)  // already one deeper than the entry above
        #expect(notebook.visibleOutline[1].level == 1)

        notebook.deleteOutlineEntry(first)
        #expect(notebook.visibleOutline.map(\.title) == ["Section"])
        #expect(notebook.visibleOutline[0].level == 0)  // nothing above it any more

        notebook.undoManager.undo()  // delete
        notebook.undoManager.undo()  // rename
        #expect(notebook.visibleOutline.map(\.title) == ["Chapter", "Section"])
        notebook.undoManager.undo()  // indent
        #expect(notebook.visibleOutline.map(\.level) == [0, 0])
    }

    @Test func entriesFollowTheirPageAndComeBackWhenADeleteIsUndone() throws {
        let folder = try TempFolder()
        let notebook = try openNotebook(folder)
        let pages = notebook.pages.map(\.id)
        notebook.setUpOutline([])
        notebook.addOutlineEntry(title: "On first", pageID: pages[0])
        notebook.addOutlineEntry(title: "On last", pageID: pages[2])

        try notebook.movePages([pages[2]], toIndex: 0)
        #expect(notebook.visibleOutline.map(\.title) == ["On last", "On first"])

        try notebook.deletePages([pages[0]])
        #expect(notebook.visibleOutline.map(\.title) == ["On last"])
        notebook.undoManager.undo()
        #expect(notebook.visibleOutline.map(\.title) == ["On last", "On first"])
    }

    @Test func outlineIsSavedAndOldFormatKeptAsMetaV3() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: package.metaURL)) as! [String: Any]
        json["formatVersion"] = 3
        let original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: package.metaURL)

        let notebook = try Notebook.open(package)
        #expect(notebook.outline == nil)
        notebook.setUpOutline([])
        notebook.addOutlineEntry(title: "Saved", pageID: notebook.pages[0].id)
        await notebook.saveChanges()

        #expect(try Data(contentsOf: package.url.appending(path: "meta.v3.json")) == original)
        let reopened = try package.readMeta()
        #expect(reopened.formatVersion == 4)
        #expect(reopened.outline?.map(\.title) == ["Saved"])
    }

    @Test func aTemplateNotebookStartsWithAnEmptyOutline() async throws {
        let folder = try TempFolder()
        let notebook = try openNotebook(folder)
        await notebook.setUpOutlineIfNeeded()
        #expect(notebook.outline == [])
    }

    @Test func anImportedPDFGetsItsOutlineFromItsText() async throws {
        let folder = try TempFolder()
        let source = try makeSlidesPDF(in: folder.url, titles: ["Groups", "Rings"])
        let package = try NotebookPackage.importPDF(from: source, in: folder.url, title: "Algebra", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        await notebook.setUpOutlineIfNeeded()
        #expect(notebook.visibleOutline.map(\.title) == ["Groups", "Rings"])
        #expect(!notebook.canUndo)  // setting up is not something the user did

        notebook.clearOutline()
        #expect(notebook.visibleOutline.isEmpty)
        await notebook.setUpOutlineIfNeeded()  // set up once only: a cleared outline stays empty
        #expect(notebook.visibleOutline.isEmpty)
        #expect(await notebook.regenerateOutlineFromText() == 2)
    }

    @Test func exportWritesTheOutlineAsBookmarks() async throws {
        let folder = try TempFolder()
        let notebook = try openNotebook(folder)
        let pages = notebook.pages.map(\.id)
        notebook.setUpOutline([])
        notebook.addOutlineEntry(title: "Start", pageID: pages[0])
        let sub = try #require(notebook.addOutlineEntry(title: "Middle", pageID: pages[1]))
        notebook.indentOutlineEntry(sub, by: 1)

        let url = try await NotebookExporter.export(notebook)
        defer { NotebookExporter.discard(url) }
        let exported = try #require(PDFDocument(url: url))
        #expect(exported.pageCount == 3)
        let entries = Outline.entries(fromBookmarksOf: exported, pageIDs: pages)
        #expect(entries.map(\.title) == ["Start", "Middle"])
        #expect(entries.map(\.level) == [0, 1])
        #expect(entries.map(\.pageID) == [pages[0], pages[1]])

        // Writing the bookmarks re-saves the pages; the file must not grow noticeably.
        notebook.clearOutline()
        let plain = try await NotebookExporter.export(notebook)
        defer { NotebookExporter.discard(plain) }
        let withOutline = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let without = try plain.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        #expect(Double(withOutline) < Double(without) * 1.1 + 2000)
    }
    @Test func addingBeforeTheOutlineWasSetUpKeepsThePDFsTitles() async throws {
        let folder = try TempFolder()
        let source = try makeSlidesPDF(in: folder.url, titles: ["Groups", "Rings"])
        let package = try NotebookPackage.importPDF(from: source, in: folder.url, title: "Algebra", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        #expect(notebook.outline == nil)
        await notebook.addToOutline(title: "My note", pageID: notebook.pages[1].id)
        #expect(notebook.visibleOutline.map(\.title) == ["Groups", "Rings", "My note"])
        notebook.undoManager.undo()
        #expect(notebook.visibleOutline.map(\.title) == ["Groups", "Rings"])
    }

    @Test func exportWithAnOutlineKeepsTextScansAndRotation() async throws {
        let folder = try TempFolder()
        let source = try makeSlidesPDF(in: folder.url, titles: ["Groups", "Rings"])
        let package = try NotebookPackage.importPDF(from: source, in: folder.url, title: "Mixed", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        // A scanned page (an embedded JPEG of noise, so its size is easy to see).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let noise = UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 2000), format: format).image { context in
            for _ in 0..<8000 {
                UIColor(white: .random(in: 0...0.8), alpha: 1).setFill()
                context.fill(CGRect(x: .random(in: 0..<1500), y: .random(in: 0..<2000), width: 20, height: 6))
            }
        }
        let scan = try #require(PDFDocument(data: try ScanPages.pdfData(fromJPEGs: [try ScanPages.jpegData(for: noise)])))
        try notebook.insertPages(try Notebook.makeEntries(from: scan), at: 2)
        try notebook.rotatePages([notebook.pages[1].id], by: 90)
        notebook.setDrawing(sampleDrawing(), for: notebook.pages[0].id)
        await notebook.setUpOutlineIfNeeded()
        #expect(notebook.visibleOutline.count == 2)

        let withOutline = try await NotebookExporter.export(notebook)
        defer { NotebookExporter.discard(withOutline) }
        notebook.clearOutline()
        let without = try await NotebookExporter.export(notebook)
        defer { NotebookExporter.discard(without) }

        let exported = try #require(PDFDocument(url: withOutline))
        #expect(exported.pageCount == 3)
        #expect(exported.page(at: 0)?.string?.contains("Groups") == true)  // still text
        let rotated = try #require(exported.page(at: 1))
        let size = PageRenderer.displayedSize(of: rotated)
        #expect(abs(size.width - 595) < 1 && abs(size.height - 842) < 1)  // landscape slide turned upright
        #expect(Outline.entries(fromBookmarksOf: exported, pageIDs: notebook.pages.map(\.id)).count == 2)
        let a = try withOutline.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let b = try without.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        #expect(Double(a) < Double(b) * 1.1 + 2000, "with outline \(a) bytes, without \(b) bytes")
    }
}
