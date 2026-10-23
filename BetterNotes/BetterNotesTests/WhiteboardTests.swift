import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Whiteboards (format version 5): one big page, no page operations, region rendering and export.
@MainActor
struct WhiteboardModelTests {
    private func makeBoard(in folder: TempFolder, background: BoardBackground = .dots) throws -> Notebook {
        try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Board", background: background, coverColor: "#3366CC"))
    }

    @Test func aWhiteboardIsOneBigBlankPageWithItsBackground() throws {
        let folder = try TempFolder()
        let board = try makeBoard(in: folder)
        #expect(board.meta.isWhiteboard && board.meta.boardBackground == .dots)
        #expect(board.pages.count == 1 && board.pages[0].size == Whiteboard.size)
        #expect(board.document?.pageCount == 1)
        let reread = try board.package.readMeta()
        #expect(reread.formatVersion == 5 && reread.kind == .whiteboard)
        // The pattern is not in the PDF: the file stays tiny.
        let size = try board.package.pdfURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size < 20_000)
    }

    @Test func aBoardKeepsAtMost30UndoSteps() throws {
        let folder = try TempFolder()
        let board = try makeBoard(in: folder)
        #expect(board.undoManager.levelsOfUndo == Whiteboard.undoLevels)
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        #expect(notebook.undoManager.levelsOfUndo == 0)  // unlimited
    }

    @Test func everyPageOperationIsRefused() throws {
        let folder = try TempFolder()
        let board = try makeBoard(in: folder)
        let id = board.pages[0].id
        let page = try Notebook.makeTemplatePage(.lined, size: .a4Portrait)
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.insertPages([page], at: 1) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.addPageAtEnd() }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.duplicatePages([id]) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.deletePages([id]) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.movePages([id], toIndex: 0) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.rotatePages([id], by: 90) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.changeTemplate(of: [id], to: .grid) }
        #expect(throws: NotebookError.whiteboardHasNoPages) { try board.copyEntries([id]) }
        #expect(board.pages.count == 1 && !board.canUndo)
    }

    @Test func pagesCannotBeMovedOntoAWhiteboard() async throws {
        let folder = try TempFolder()
        let board = try makeBoard(in: folder)
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        try notebook.addPageAtEnd()
        await #expect(throws: NotebookError.whiteboardHasNoPages) {
            try await PageTransfer.transfer(
                [notebook.pages[0].id], from: notebook, toNotebookAt: board.package.url, move: true,
                registry: OpenNotebookRegistry())
        }
        #expect(notebook.pages.count == 2)  // nothing removed from the source
    }

    @Test func aVersion4NotebookIsKeptAsMetaV4() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: package.metaURL)) as! [String: Any]
        json["formatVersion"] = 4
        let original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: package.metaURL)
        var meta = try package.readMeta()
        #expect(meta.kind == nil && !meta.isWhiteboard)
        meta.title = "Renamed"
        try package.writeMeta(meta)
        #expect(try Data(contentsOf: package.url.appending(path: "meta.v4.json")) == original)
    }
}

struct WhiteboardRegionTests {
    @Test func theRegionIsTheInkAndObjectsWithAMarginInsideTheBoard() {
        let ink = CGRect(x: 5000, y: 5000, width: 200, height: 100)
        let image = PageObject(frame: CGRect(x: 5400, y: 4900, width: 100, height: 100), content: .text(TextObject(text: "x", fontSize: 16, colorHex: "#000000")))
        let region = Whiteboard.contentRegion(inkBounds: ink, objects: [image])
        #expect(region == CGRect(x: 5000 - 60, y: 4900 - 60, width: 500 + 120, height: 200 + 120))
        // Near the edge the margin is cut off by the board.
        let corner = Whiteboard.contentRegion(inkBounds: CGRect(x: 10, y: 10, width: 50, height: 50), objects: [])
        #expect(corner.minX == 0 && corner.minY == 0)
    }

    @Test func anEmptyBoardGivesAnA4AreaInTheMiddle() {
        let region = Whiteboard.contentRegion(inkBounds: .null, objects: [])
        #expect(region.size == CGSize(width: 595, height: 842))
        #expect(abs(region.midX - 5000) < 1 && abs(region.midY - 5000) < 1)
    }

    @Test func bigRegionsGetALowerInkResolution() {
        #expect(Whiteboard.inkScale(for: CGRect(x: 0, y: 0, width: 600, height: 800), preferred: 4) == 4)
        let full = Whiteboard.inkScale(for: Whiteboard.bounds, preferred: 4)
        #expect(full < 1 && full * full * 10_000 * 10_000 <= 64_000_001)
    }

    @Test func theBackgroundPatternIsDrawn() {
        func darkPixels(_ background: BoardBackground) -> Int {
            let image = PageRenderer.renderBoard(
                region: CGRect(x: 1000, y: 1000, width: 200, height: 200), background: background,
                drawing: PKDrawing(), scale: 2)
            let pixels = PixelReader(image)
            var count = 0
            for y in stride(from: 0, to: pixels.height, by: 1) {
                for x in stride(from: 0, to: pixels.width, by: 1) where !pixels.isWhite(x, y) { count += 1 }
            }
            return count
        }
        #expect(darkPixels(.plain) == 0)
        #expect(darkPixels(.dots) > 0)
        #expect(darkPixels(.grid) > darkPixels(.dots))
    }
}

@MainActor
struct WhiteboardExportTests {
    @Test func exportIsOnePageAroundTheInk() async throws {
        let folder = try TempFolder()
        let board = try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Board", background: .grid, coverColor: "#3366CC"))
        let id = board.pages[0].id
        board.setDrawing(lineDrawing(from: CGPoint(x: 4000, y: 4000), to: CGPoint(x: 4600, y: 4300)), for: id)

        let url = try await NotebookExporter.export(board)
        defer { NotebookExporter.discard(url) }
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        let size = try #require(document.page(at: 0)).bounds(for: .mediaBox).size
        let ink = board.drawing(for: id).bounds
        #expect(abs(size.width - (ink.width + 120)) < 2 && abs(size.height - (ink.height + 120)) < 2)
    }

    @Test func aNearlyFullBoardExportsWithoutHugeMemory() async throws {
        let folder = try TempFolder()
        let board = try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Full", background: .plain, coverColor: "#3366CC"))
        let id = board.pages[0].id
        let corners = lineDrawing(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 9900, y: 9900))
        board.setDrawing(corners, for: id)
        let url = try await NotebookExporter.export(board)
        defer { NotebookExporter.discard(url) }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(bytes > 0 && bytes < 40_000_000)
        #expect(PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox).width ?? 0 > 9000)
    }

    @Test func theCoverShowsTheInkNotTheWholeBoard() throws {
        let folder = try TempFolder()
        let board = try Notebook.open(try NotebookPackage.createWhiteboard(
            in: folder.url, title: "Cover", background: .plain, coverColor: "#3366CC"))
        let drawing = lineDrawing(from: CGPoint(x: 5000, y: 5000), to: CGPoint(x: 5300, y: 5000), width: 20)
        let image = PageRenderer.renderBoardPreview(
            page: board.pages[0], background: .plain, drawing: drawing, images: nil, width: 400, maximumScale: 0.7)
        #expect(image.size.width <= 401)
        let pixels = PixelReader(image)
        var dark = 0
        for x in 0..<pixels.width where pixels.isDark(x, pixels.height / 2) { dark += 1 }
        #expect(dark > pixels.width / 3)  // the stroke crosses most of the picture
    }
}
