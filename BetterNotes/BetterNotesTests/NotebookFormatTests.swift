import Foundation
import PDFKit
import PencilKit
import Testing
@testable import BetterNotes

struct MetaJSONTests {
    @Test func roundTripKeepsEverything() throws {
        let folder = try TempFolder()
        let pageA = PageMeta(template: .grid, size: .a4Landscape, rotation: 90)
        let pageB = PageMeta(template: .pdf, size: PageSize(width: 612, height: 792))
        let meta = NotebookMeta(
            title: "Analysis", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            coverColor: "#FF8800", pages: [pageA, pageB])
        let package = NotebookPackage(url: folder.url)

        try package.writeMeta(meta)

        #expect(try package.readMeta() == meta)
    }

    @Test func fileIsAtTheCurrentFormatVersionAndKeepsPageOrder() throws {
        let folder = try TempFolder()
        let pages = (0..<5).map { _ in PageMeta(template: .blank, size: .a4Portrait) }
        let meta = NotebookMeta(
            title: "Order", createdAt: Date(timeIntervalSince1970: 0), coverColor: "#000000", pages: pages)
        let package = NotebookPackage(url: folder.url)

        try package.writeMeta(meta)

        let json = try String(contentsOf: package.metaURL, encoding: .utf8)
        #expect(json.contains("\"formatVersion\" : \(NotebookMeta.currentFormatVersion)"))
        #expect(try package.readMeta().pages.map(\.id) == pages.map(\.id))
    }

    @Test func newerFormatVersionIsRefusedAndFileStaysUntouched() throws {
        let folder = try TempFolder()
        let package = NotebookPackage(url: folder.url)
        // A made-up future file with fields this version does not know.
        let future = Data(#"{"formatVersion": 99, "somethingNew": [1, 2, 3]}"#.utf8)
        try future.write(to: package.metaURL)

        #expect(throws: NotebookError.unsupportedFormatVersion(99)) { try package.readMeta() }
        #expect(try Data(contentsOf: package.metaURL) == future)
    }
}

struct TemplateGeneratorTests {
    @Test(arguments: [PageTemplate.blank, .lined, .grid, .dotted], [PageSize.a4Portrait, .a4Landscape])
    func generatedPageHasTheRightSize(template: PageTemplate, size: PageSize) throws {
        let data = try TemplateGenerator.makePDF(for: [PageMeta(template: template, size: size)])

        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.width == size.width && box.height == size.height)
    }

    @Test(arguments: PaperFormat.allCases)
    func everyPaperFormatWorksInBothOrientations(format: PaperFormat) throws {
        let pages = [
            PageMeta(template: .lined, size: format.portrait),
            PageMeta(template: .grid, size: format.portrait.landscape),
        ]

        let document = try #require(PDFDocument(data: try TemplateGenerator.makePDF(for: pages)))

        let width = format.portrait.width, height = format.portrait.height
        let portraitBox = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let landscapeBox = try #require(document.page(at: 1)).bounds(for: .mediaBox)
        #expect(portraitBox.size == CGSize(width: width, height: height))
        #expect(landscapeBox.size == CGSize(width: height, height: width))
        #expect(height > width)
    }

    @Test func mixedPagesKeepOrderAndSizes() throws {
        let pages = [
            PageMeta(template: .lined, size: .a4Portrait),
            PageMeta(template: .grid, size: .a4Landscape),
            PageMeta(template: .dotted, size: .a4Portrait),
        ]

        let document = try #require(PDFDocument(data: try TemplateGenerator.makePDF(for: pages)))

        #expect(document.pageCount == 3)
        let widths = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).width }
        #expect(widths == [595, 842, 595])
    }

    @Test func linedPageContainsDrawingAndBlankDoesNot() throws {
        let blank = try TemplateGenerator.makePDF(for: [PageMeta(template: .blank, size: .a4Portrait)])
        let lined = try TemplateGenerator.makePDF(for: [PageMeta(template: .lined, size: .a4Portrait)])

        #expect(lined.count > blank.count)
    }

    @Test func importedPdfPagesCannotBeGenerated() {
        #expect(throws: NotebookError.cannotGenerateTemplate(.pdf)) {
            try TemplateGenerator.makePDF(for: [PageMeta(template: .pdf, size: .a4Portrait)])
        }
    }
}

struct NotebookPackageTests {
    @Test func createMakesAFullPackage() throws {
        let folder = try TempFolder()

        let package = try makeNotebook(in: folder.url, title: "Lecture 3")

        #expect(package.url.lastPathComponent == "Lecture 3.inkbook")
        let meta = try package.readMeta()
        let document = try #require(PDFDocument(url: package.pdfURL))
        #expect(meta.pages.count == document.pageCount)
        #expect(meta.title == "Lecture 3")
        for sub in ["drawings", "objects", "thumbnails"] {
            #expect(FileManager.default.fileExists(atPath: package.url.appending(path: sub).path))
        }
        // The hidden staging folder must be gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["Lecture 3.inkbook"])
    }

    @Test func sameTitleGetsANumberInsteadOfOverwriting() throws {
        let folder = try TempFolder()

        let first = try makeNotebook(in: folder.url, title: "Notes")
        let second = try makeNotebook(in: folder.url, title: "Notes")
        let third = try makeNotebook(in: folder.url, title: "Notes")

        #expect(first.url.lastPathComponent == "Notes.inkbook")
        #expect(second.url.lastPathComponent == "Notes (2).inkbook")
        #expect(third.url.lastPathComponent == "Notes (3).inkbook")
        #expect(try first.readMeta().id != second.readMeta().id)
    }

    @Test func titlesBecomeSafeFileNames() {
        #expect(NotebookPackage.fileName(forTitle: "a/b:c") == "a-b-c")
        #expect(NotebookPackage.fileName(forTitle: "  ") == "Untitled")
        #expect(NotebookPackage.fileName(forTitle: ".hidden") == "hidden")
    }

    @Test func failedAtomicWriteKeepsTheOldFile() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var meta = try package.readMeta()
        let before = try Data(contentsOf: package.metaURL)

        // Make the notebook folder read-only so the write cannot even create its temporary file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path) }
        meta.title = "Changed"

        #expect(throws: (any Error).self) { try package.writeMeta(meta) }
        #expect(try Data(contentsOf: package.metaURL) == before)
        #expect(try package.readMeta().title == "Test")
    }

    @Test func inkIsSavedAndLoadedPerPageID() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let pageA = UUID(), pageB = UUID()

        try package.saveDrawing(sampleDrawing(), for: pageA)

        let loaded = try #require(try package.loadDrawing(for: pageA))
        #expect(loaded.strokes.count == 1)
        // Compare content, not bytes: PencilKit may re-encode a loaded drawing slightly differently.
        let stroke = try #require(loaded.strokes.first)
        #expect(stroke.ink.inkType == .pen)
        #expect(stroke.path.count == 2)
        #expect(stroke.path.first?.location == CGPoint(x: 10, y: 10))
        #expect(stroke.path.last?.location == CGPoint(x: 100, y: 80))
        #expect(try package.loadDrawing(for: pageB) == nil)  // another page has no ink
    }

    @Test func savingInkTwiceReplacesIt() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let page = UUID()

        try package.saveDrawing(sampleDrawing(), for: page)
        try package.saveDrawing(PKDrawing(), for: page)

        #expect(try package.loadDrawing(for: page)?.strokes.isEmpty == true)
    }
}
