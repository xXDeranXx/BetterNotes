import Foundation
import Testing
import UIKit
@testable import BetterNotes

struct ObjectImageImportTests {
    private func image(width: Int, height: Int, opaque: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.blue.withAlphaComponent(opaque ? 1 : 0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
    }

    private func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }
    private func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }

    @Test func aLargePhotoIsShrunkAndStoredAsJPEG() throws {
        let photo = try #require(image(width: 4000, height: 3000).jpegData(compressionQuality: 0.9))
        let prepared = try ObjectImageImport.prepare(photo)
        #expect(prepared.fileExtension == "jpg" && isJPEG(prepared.data))
        #expect(prepared.pixelSize == CGSize(width: 2000, height: 1500))
        #expect(UIImage(data: prepared.data)?.size == CGSize(width: 2000, height: 1500))
    }

    @Test func aScreenshotStaysPNGAndIsShrunk() throws {
        let screenshot = try #require(image(width: 2732, height: 2048).pngData())
        let prepared = try ObjectImageImport.prepare(screenshot)
        #expect(prepared.fileExtension == "png" && isPNG(prepared.data))
        #expect(prepared.pixelSize.width == 2000)
    }

    @Test func aSmallImageInTheRightFormatIsKeptByteForByte() throws {
        let photo = try #require(image(width: 800, height: 600).jpegData(compressionQuality: 0.9))
        #expect(try ObjectImageImport.prepare(photo).data == photo)
        let screenshot = try #require(image(width: 800, height: 600).pngData())
        #expect(try ObjectImageImport.prepare(screenshot).data == screenshot)
    }

    @Test func anImageWithTransparencyBecomesPNG() throws {
        let prepared = try ObjectImageImport.prepare(image(width: 300, height: 200, opaque: false))
        #expect(prepared.fileExtension == "png")
        let opaque = try ObjectImageImport.prepare(image(width: 300, height: 200))
        #expect(opaque.fileExtension == "jpg")
    }

    @Test func notAnImageIsAnError() {
        #expect(throws: NotebookError.imageUnreadable) { try ObjectImageImport.prepare(Data("hello".utf8)) }
    }

    @Test func theDefaultFrameFitsThePageAndIsCentered() {
        let page = CGSize(width: 595, height: 842)
        // A big landscape screenshot: 60 % of the page width.
        let wide = ObjectImageImport.defaultFrame(pixelSize: CGSize(width: 2000, height: 1500), pageSize: page, center: CGPoint(x: 300, y: 400))
        #expect(wide.width == 357 && abs(wide.height - 268) <= 1)
        #expect(abs(wide.midX - 300) <= 1 && abs(wide.midY - 400) <= 1)
        // A small icon keeps its Retina size.
        let small = ObjectImageImport.defaultFrame(pixelSize: CGSize(width: 100, height: 60), pageSize: page, center: CGPoint(x: 300, y: 400))
        #expect(small.size == CGSize(width: 50, height: 30))
        // Near the edge it is moved inside the page.
        let edge = ObjectImageImport.defaultFrame(pixelSize: CGSize(width: 400, height: 400), pageSize: page, center: CGPoint(x: 590, y: 5))
        #expect(edge.maxX <= 595 && edge.minY >= 0)
    }
}

@MainActor
struct InsertImageTests {
    @Test func insertingWritesTheFileAndAddsOneUndoableObject() async throws {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        notebook.autosaveDelay = .seconds(60)
        let page = notebook.pages[0].id
        let prepared = try ObjectImageImport.prepare(redPNG(width: 400, height: 200))

        let object = try notebook.insertImage(prepared, on: page, center: CGPoint(x: 300, y: 400))

        let file = try #require(object.imageFile)
        #expect(file.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: notebook.package.objectFileURL(named: file).path))
        #expect(object.frame.size == CGSize(width: 200, height: 100))
        #expect(notebook.objects(on: page) == [object])
        #expect(notebook.undoManager.undoActionName == "Insert Image")

        notebook.undoManager.undo()
        #expect(notebook.objects(on: page).isEmpty)
        // The file stays: redo needs it.
        #expect(FileManager.default.fileExists(atPath: notebook.package.objectFileURL(named: file).path))
        notebook.undoManager.redo()
        #expect(notebook.objects(on: page) == [object])
    }

    @Test func theOverlayShowsObjectsInOrderAndReusesTheirViews() throws {
        let overlay = PageOverlayView(pageID: UUID())
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        let picture = imageObject(file: "a.png", frame: CGRect(x: 10, y: 10, width: 100, height: 50))
        var text = textObject("Hi", frame: CGRect(x: 20, y: 100, width: 200, height: 30))

        overlay.showObjects([picture, text]) { _ in UIImage() }
        let textView = try #require(overlay.objectViews[text.id] as? TextBoxView)
        #expect(overlay.objectsLayer.subviews.count == 2)
        #expect(overlay.objectsLayer.subviews.last === textView)  // later objects on top

        text.frame.origin.y = 200
        overlay.showObjects([text]) { _ in UIImage() }
        #expect(overlay.objectViews[text.id] === textView)  // the same view, moved
        #expect(textView.frame.minY == 200)
        #expect(overlay.objectsLayer.subviews.count == 1)
    }
}
