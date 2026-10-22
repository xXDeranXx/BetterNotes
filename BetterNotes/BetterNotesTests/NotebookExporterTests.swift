import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

@MainActor
struct NotebookExporterTests {
    /// An imported notebook with pages "P1" ... "Pn".
    private func makeOpenNotebook(in folder: TempFolder, pageCount: Int = 3, title: String = "Slides") throws -> Notebook {
        let source = try makeLabeledPDF(in: folder.url, labels: (1...pageCount).map { "P\($0)" })
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: title, coverColor: "#000000")
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)
        return notebook
    }

    private func exported(_ notebook: Notebook, pageIDs: Set<UUID>? = nil) async throws -> PDFDocument {
        let url = try await NotebookExporter.export(notebook, pageIDs: pageIDs)
        defer { NotebookExporter.discard(url) }
        return try #require(PDFDocument(data: try Data(contentsOf: url)))
    }

    @Test func hasTheSamePageCountAndSizes() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        try notebook.rotatePages([notebook.pages[1].id], by: 90)

        let document = try await exported(notebook)

        #expect(document.pageCount == 3)
        for index in 0..<3 {
            let source = try #require(notebook.document?.page(at: index))
            let page = try #require(document.page(at: index))
            let expected = PageRenderer.displayedSize(of: source)
            #expect(page.bounds(for: .cropBox).size == expected)
            #expect(page.rotation == 0)  // the rotation is baked into the page
        }
        #expect(document.page(at: 1)?.bounds(for: .cropBox).size == CGSize(width: 842, height: 595))
    }

    @Test func keepsTheOriginalTextAsText() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        notebook.setDrawing(lineDrawing(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 300, y: 300)), for: notebook.pages[0].id)

        let document = try await exported(notebook)

        #expect(document.page(at: 0)?.string?.contains("P1") == true)
        #expect(document.findString("P3", withOptions: []).count == 1)
    }

    @Test func inkIsOnTheRightPageAtTheRightPlace() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        // A stroke near the TOP of page 2 only.
        notebook.setDrawing(
            lineDrawing(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 300, y: 300)), for: notebook.pages[1].id)

        let document = try await exported(notebook)

        for index in 0..<3 {
            let image = PageRenderer.render(page: try #require(document.page(at: index)), drawing: PKDrawing(), scale: 1)
            let pixels = PixelReader(image)
            #expect(pixels.isDark(200, 300) == (index == 1))
            #expect(pixels.isWhite(200, 842 - 300))  // never mirrored
        }
    }

    @Test func inkTurnsWithARotatedPage() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 1)
        notebook.setDrawing(
            lineDrawing(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 300, y: 300)), for: notebook.pages[0].id)
        try notebook.rotatePages([notebook.pages[0].id], by: 90)

        let document = try await exported(notebook)
        let rendered = PageRenderer.render(page: try #require(document.page(at: 0)), drawing: PKDrawing(), scale: 1)
        let direct = PageRenderer.render(
            page: try #require(notebook.document?.page(at: 0)), drawing: notebook.drawing(for: notebook.pages[0].id), scale: 1)

        // Turned 90 degrees clockwise, (200, 300) lands at (842 - 300, 200).
        #expect(PixelReader(rendered).isDark(542, 200))
        #expect(PixelReader(direct).isDark(542, 200))
    }

    @Test func onlyTheSelectedPagesInNotebookOrder() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 4)

        let document = try await exported(notebook, pageIDs: [notebook.pages[3].id, notebook.pages[1].id])

        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("P2") == true)
        #expect(document.page(at: 1)?.string?.contains("P4") == true)
    }

    @Test func aPageWithoutInkLooksLikeTheOriginal() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 2)

        let document = try await exported(notebook)

        let original = PixelReader(PageRenderer.render(
            page: try #require(notebook.document?.page(at: 0)), drawing: PKDrawing(), scale: 1))
        let copy = PixelReader(PageRenderer.render(
            page: try #require(document.page(at: 0)), drawing: PKDrawing(), scale: 1))
        #expect(original.width == copy.width && original.height == copy.height)
        for (x, y) in [(55, 70), (60, 80), (300, 400), (10, 10), (594, 841)] {
            #expect(abs(original.rgb(x, y).r - copy.rgb(x, y).r) < 20)
        }
    }

    @Test func exportingChangesNothingInTheNotebook() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let before = try Data(contentsOf: notebook.package.pdfURL)

        _ = try await exported(notebook)

        #expect(!notebook.hasUnsavedChanges)
        #expect(try Data(contentsOf: notebook.package.pdfURL) == before)
        #expect(notebook.loadedPageIDs.isEmpty)  // drawings read for export are not kept
    }

    @Test func aCancelledExportLeavesNothingBehind() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 50)
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Export-") }

        let task = Task { try await NotebookExporter.export(notebook) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Export-") }
        #expect(Set(after).subtracting(before).isEmpty)
    }

    @Test func fileNamesAreSafe() {
        #expect(NotebookExporter.fileName(for: "Analysis 1") == "Analysis 1.pdf")
        #expect(NotebookExporter.fileName(for: "a/b:c*d?") == "abcd.pdf")
        #expect(NotebookExporter.fileName(for: "  ") == "Notebook.pdf")
    }
}
