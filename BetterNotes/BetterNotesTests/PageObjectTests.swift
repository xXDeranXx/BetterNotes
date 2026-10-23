import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// A solid red PNG of the given pixel size.
func redPNG(width: Int = 40, height: Int = 20) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

func imageObject(file: String, frame: CGRect) -> PageObject {
    PageObject(frame: frame, content: .image(ImageObject(file: file)))
}

func textObject(_ text: String, frame: CGRect, size: Double = 16) -> PageObject {
    PageObject(frame: frame, content: .text(TextObject(text: text, fontSize: size, colorHex: "#000000")))
}

struct PageObjectFormatTests {
    @Test func objectsRoundTripThroughJSONWithFlatKeys() throws {
        let objects = [
            imageObject(file: "a.jpg", frame: CGRect(x: 10, y: 20, width: 30, height: 40)),
            textObject("Hello\nworld", frame: CGRect(x: 1.5, y: 2, width: 200, height: 50), size: 20),
        ]
        let data = try JSONEncoder().encode(objects)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\":\"image\"") && json.contains("\"file\":\"a.jpg\""))
        #expect(!json.contains("_0"))
        #expect(try JSONDecoder().decode([PageObject].self, from: data) == objects)
    }

    @Test func anUnknownObjectTypeIsAnError() {
        let json = #"[{"id":"6F1C5C8E-2D7E-4F1B-9C0A-1B2C3D4E5F60","x":0,"y":0,"width":1,"height":1,"type":"video"}]"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([PageObject].self, from: Data(json.utf8)) }
    }

    @Test func theFingerprintChangesWhenAnObjectMoves() {
        var object = textObject("A", frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        let before = PageObject.fingerprint(of: [object])
        #expect(PageObject.fingerprint(of: [object]) == before)  // stable
        object.frame.origin.x = 5
        #expect(PageObject.fingerprint(of: [object]) != before)
    }

    @Test func aTextBoxGrowsWithItsText() {
        let one = TextObject(text: "Short", fontSize: 16, colorHex: "#000000")
        let many = TextObject(text: String(repeating: "Many words wrap here. ", count: 10), fontSize: 16, colorHex: "#000000")
        let oneHeight = TextBoxLayout.height(of: one, width: 200)
        #expect(oneHeight > 16 && oneHeight < 40)
        #expect(TextBoxLayout.height(of: many, width: 200) > oneHeight * 3)
        // An empty box still has one line, and a trailing newline adds a line.
        #expect(TextBoxLayout.height(of: TextObject(text: "", fontSize: 16, colorHex: "#000000"), width: 200) == oneHeight)
        #expect(TextBoxLayout.height(of: TextObject(text: "Short\n", fontSize: 16, colorHex: "#000000"), width: 200) > oneHeight)
    }
}

/// Format version 2 (milestone 8): old notebooks open, and are migrated with a copy kept.
@MainActor
struct FormatMigrationTests {
    /// Turns a notebook's meta.json into the version 1 format (no `objects` keys).
    private func makeVersion1(_ package: NotebookPackage) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: package.metaURL)) as! [String: Any]
        json["formatVersion"] = 1
        json["pages"] = (json["pages"] as! [[String: Any]]).map { page in
            var page = page
            page["objects"] = nil
            return page
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: package.metaURL)
        return data
    }

    @Test func aVersion1NotebookOpensWithoutObjects() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        _ = try makeVersion1(package)

        let meta = try package.readMeta()
        #expect(meta.formatVersion == 1)
        #expect(meta.pages.count == 1 && meta.pages[0].objects.isEmpty)
    }

    @Test func theFirstWriteKeepsTheVersion1FileOnceAndWritesTheCurrentVersion() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let original = try makeVersion1(package)

        var meta = try package.readMeta()
        meta.title = "Renamed"
        try package.writeMeta(meta)

        let copy = package.url.appending(path: "meta.v1.json")
        #expect(try Data(contentsOf: copy) == original)
        #expect(try package.readMeta().formatVersion == NotebookMeta.currentFormatVersion)
        #expect(try package.readMeta().title == "Renamed")

        // Later writes leave the copy alone.
        meta.title = "Again"
        try package.writeMeta(meta)
        #expect(try Data(contentsOf: copy) == original)
    }

    @Test func aPageChangeAlsoKeepsTheVersion1File() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let original = try makeVersion1(package)
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)

        try notebook.addPageAtEnd()
        await notebook.saveChanges()

        #expect(try Data(contentsOf: package.url.appending(path: "meta.v1.json")) == original)
        #expect(try package.readMeta().formatVersion == NotebookMeta.currentFormatVersion)
        #expect(try package.readMeta().pages.count == 2)
    }

    @Test func newNotebooksAreVersion2WithoutACopy() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        #expect(try package.readMeta().formatVersion == NotebookMeta.currentFormatVersion)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "meta.v1.json").path))
    }
}

@MainActor
struct NotebookObjectTests {
    private func makeOpen(_ folder: TempFolder) throws -> Notebook {
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        notebook.autosaveDelay = .seconds(60)
        return notebook
    }

    @Test func addMoveAndDeleteAreEachOneUndoStep() throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let page = notebook.pages[0].id
        var box = textObject("Hi", frame: CGRect(x: 10, y: 10, width: 100, height: 30))

        notebook.addObject(box, to: page, actionName: "Add Text")
        box.frame.origin = CGPoint(x: 50, y: 60)
        notebook.updateObject(box, on: page, actionName: "Move")
        #expect(notebook.objects(on: page) == [box])

        notebook.removeObjects([box.id], from: page)
        #expect(notebook.objects(on: page).isEmpty)

        notebook.undoManager.undo()  // delete
        #expect(notebook.objects(on: page) == [box])
        notebook.undoManager.undo()  // move
        #expect(notebook.objects(on: page).first?.frame.origin == CGPoint(x: 10, y: 10))
        notebook.undoManager.undo()  // add
        #expect(notebook.objects(on: page).isEmpty)
        notebook.undoManager.redo()
        #expect(notebook.objects(on: page).count == 1)
    }

    @Test func aChangeTellsTheEditorAndBumpsThePageRevision() throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let page = notebook.pages[0].id
        var changed: [UUID] = []
        notebook.onObjectsChange = { changed.append($0) }

        notebook.addObject(textObject("A", frame: .init(x: 0, y: 0, width: 50, height: 20)), to: page, actionName: "Add")
        notebook.undoManager.undo()

        #expect(changed == [page, page])
        #expect(notebook.revisions[page] == 2)
    }

    @Test func anObjectOnlyChangeIsSavedToMetaWithoutRewritingThePDF() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let page = notebook.pages[0].id
        let pdfDate = try FileManager.default.attributesOfItem(atPath: notebook.package.pdfURL.path)[.modificationDate] as! Date
        let box = textObject("Saved", frame: .init(x: 5, y: 5, width: 80, height: 30))

        notebook.addObject(box, to: page, actionName: "Add")
        #expect(notebook.hasUnsavedChanges)
        await notebook.saveChanges()

        #expect(!notebook.hasUnsavedChanges)
        #expect(try notebook.package.readMeta().pages[0].objects == [box])
        let pdfDateAfter = try FileManager.default.attributesOfItem(atPath: notebook.package.pdfURL.path)[.modificationDate] as! Date
        #expect(pdfDateAfter == pdfDate)
        // And it reopens with the object.
        #expect(try Notebook.open(notebook.package).objects(on: page) == [box])
    }

    @Test func anObjectChangeDuringASaveStaysUnsaved() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)  // something for the background part of the save
        notebook.saveHook = { @MainActor in
            notebook.addObject(textObject("Late", frame: .init(x: 0, y: 0, width: 50, height: 20)), to: page, actionName: "Add")
        }
        await notebook.saveChanges()
        notebook.saveHook = nil
        // The meta.json write happens on the main thread after the hook, so it already has the
        // object; either way nothing may be lost: after one more save everything is on disk.
        await notebook.saveChanges()
        #expect(!notebook.hasUnsavedChanges)
        #expect(try notebook.package.readMeta().pages[0].objects.count == 1)
    }

    @Test func objectsTravelWithPageOperations() throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let first = notebook.pages[0].id
        let box = textObject("Page one", frame: .init(x: 5, y: 5, width: 80, height: 30))
        notebook.addObject(box, to: first, actionName: "Add")

        // Duplicate: the copy has the object with a new id.
        let copyID = try notebook.duplicatePages([first])[0]
        let copied = notebook.objects(on: copyID)
        #expect(copied.count == 1 && copied[0].id != box.id && copied[0].content == box.content)

        // Delete and undo: the object comes back with its page.
        try notebook.deletePages([first])
        notebook.undoManager.undo()
        #expect(notebook.objects(on: first) == [box])

        // Moving the page keeps its objects.
        try notebook.movePages([first], toIndex: 1)
        #expect(notebook.pages[1].id == first)
        #expect(notebook.objects(on: first) == [box])
    }

    @Test func transferCopiesTheImageFilesIntoTheOtherNotebook() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpen(folder)
        let targetPackage = try makeNotebook(in: folder.url, title: "Target")
        let page = notebook.pages[0].id
        try notebook.package.writeObjectFile(redPNG(), named: "red.png")
        notebook.addObject(imageObject(file: "red.png", frame: .init(x: 0, y: 0, width: 40, height: 20)), to: page, actionName: "Add")

        try await PageTransfer.transfer([page], from: notebook, toNotebookAt: targetPackage.url, move: false)

        #expect(FileManager.default.fileExists(atPath: targetPackage.objectFileURL(named: "red.png").path))
        let target = try Notebook.open(targetPackage)
        #expect(target.pages[1].objects.first?.imageFile == "red.png")
    }
}

struct PageRendererObjectTests {
    private func blankPage() throws -> PDFPage {
        let data = try TemplateGenerator.makePDF(for: [PageMeta(template: .blank, size: .a4Portrait)])
        return try #require(PDFDocument(data: data)?.page(at: 0))
    }

    private func imageFolder() throws -> (TempFolder, ObjectImageSource) {
        let folder = try TempFolder()
        try redPNG().write(to: folder.url.appending(path: "red.png"))
        return (folder, ObjectImageSource(folder: folder.url))
    }

    private func isRed(_ pixels: PixelReader, _ x: Int, _ y: Int) -> Bool {
        let c = pixels.rgb(x, y)
        return c.r > 200 && c.g < 60 && c.b < 60
    }

    @Test func anImageIsDrawnInItsFrameTheRightWayUp() throws {
        let (folder, images) = try imageFolder()
        defer { withExtendedLifetime(folder) {} }  // the folder holds the image file
        let object = imageObject(file: "red.png", frame: CGRect(x: 100, y: 50, width: 200, height: 100))
        let image = PageRenderer.render(page: try blankPage(), drawing: PKDrawing(), objects: [object], images: images, scale: 1)

        let pixels = PixelReader(image)
        #expect(isRed(pixels, 200, 100))
        #expect(isRed(pixels, 102, 52) && isRed(pixels, 297, 147))
        #expect(pixels.isWhite(200, 160) && pixels.isWhite(90, 100))
    }

    @Test func inkIsOnTopOfObjects() throws {
        let (folder, images) = try imageFolder()
        defer { withExtendedLifetime(folder) {} }  // the folder holds the image file
        let object = imageObject(file: "red.png", frame: CGRect(x: 100, y: 50, width: 200, height: 100))
        let ink = lineDrawing(from: CGPoint(x: 120, y: 100), to: CGPoint(x: 280, y: 100))
        let image = PageRenderer.render(page: try blankPage(), drawing: ink, objects: [object], images: images, scale: 1)

        let pixels = PixelReader(image)
        #expect(pixels.isDark(200, 100))  // ink over the image
        #expect(isRed(pixels, 200, 130))  // the image beside the ink
    }

    @Test func textIsDrawnInsideItsBox() throws {
        let object = textObject("WWWWWWWW", frame: CGRect(x: 50, y: 300, width: 300, height: 60), size: 40)
        let image = PageRenderer.render(page: try blankPage(), drawing: PKDrawing(), objects: [object], scale: 1)

        let pixels = PixelReader(image)
        let darkInBox = (55..<345).contains { x in (305..<355).contains { y in pixels.isDark(x, y) } }
        #expect(darkInBox)
        #expect(!(0..<595).contains { x in (0..<290).contains { y in pixels.isDark(x, y) } })
    }

    @Test func aMissingImageFileDrawsAGreyBox() throws {
        let object = imageObject(file: "gone.png", frame: CGRect(x: 100, y: 50, width: 200, height: 100))
        let image = PageRenderer.render(
            page: try blankPage(), drawing: PKDrawing(), objects: [object],
            images: ObjectImageSource(folder: URL(filePath: "/nonexistent")), scale: 1)
        let pixels = PixelReader(image)
        #expect(!pixels.isWhite(200, 100) && !isRed(pixels, 200, 100))
    }

    @Test(arguments: [90, 180, 270])
    func objectsTurnWithThePage(rotation: Int) throws {
        let (folder, images) = try imageFolder()
        defer { withExtendedLifetime(folder) {} }  // the folder holds the image file
        let page = try blankPage()
        page.rotation = rotation
        let object = imageObject(file: "red.png", frame: CGRect(x: 20, y: 20, width: 60, height: 60))  // top-left corner
        let image = PageRenderer.render(page: page, drawing: PKDrawing(), objects: [object], images: images, scale: 1)

        let pixels = PixelReader(image)
        let (x, y): (Int, Int) = switch rotation {
        case 90: (842 - 50, 50)
        case 180: (595 - 50, 842 - 50)
        default: (50, 595 - 50)
        }
        #expect(isRed(pixels, x, y))
        #expect(!isRed(pixels, 50, 50) || rotation == 0)
    }
}

@MainActor
struct ObjectExportTests {
    @Test func exportedTextBoxesStayTextAndImagesAreThere() async throws {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url, template: .blank))
        notebook.autosaveDelay = .seconds(60)
        let page = notebook.pages[0].id
        try notebook.package.writeObjectFile(redPNG(), named: "red.png")
        notebook.addObject(imageObject(file: "red.png", frame: .init(x: 100, y: 400, width: 200, height: 100)), to: page, actionName: "Add")
        notebook.addObject(textObject("Searchable note", frame: .init(x: 50, y: 100, width: 300, height: 40)), to: page, actionName: "Add")

        let url = try await NotebookExporter.export(notebook)
        defer { NotebookExporter.discard(url) }
        let document = try #require(PDFDocument(url: url))
        #expect(document.page(at: 0)?.string?.contains("Searchable note") == true)

        let picture = PageRenderer.render(page: try #require(document.page(at: 0)), drawing: PKDrawing(), scale: 1)
        let c = PixelReader(picture).rgb(200, 450)
        #expect(c.r > 200 && c.g < 60)
    }
}
