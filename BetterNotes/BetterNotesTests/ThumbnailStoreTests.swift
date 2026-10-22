import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

@MainActor
struct ThumbnailStoreTests {
    private func makeOpenNotebook(in folder: TempFolder, pageCount: Int = 3) throws -> Notebook {
        let source = try makeLabeledPDF(in: folder.url, labels: (1...pageCount).map { "P\($0)" })
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "T", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)
        return notebook
    }

    private func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aThumbnailIsHalfThePageSizeAndShowsTheInk() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0]
        notebook.setDrawing(lineDrawing(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 300, y: 400), width: 20), for: page.id)
        let store = ThumbnailStore(notebook: notebook)

        let image = try #require(await store.image(for: page))

        let pixels = PixelReader(image)
        #expect(pixels.width == 298 && pixels.height == 421)  // 595 x 842 at scale 0.5
        #expect(pixels.isDark(100, 200))  // the stroke, at half size
        #expect(pixels.isWhite(100, 300))  // not where there is nothing
    }

    @Test func theSecondRequestComesFromTheCache() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let store = ThumbnailStore(notebook: notebook)

        _ = await store.image(for: notebook.pages[0])
        _ = await store.image(for: notebook.pages[0])

        #expect(store.renderCount == 1)
    }

    @Test func newInkChangesTheKeyAndTheNextRequestIsDrawnAgain() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0]
        let store = ThumbnailStore(notebook: notebook)
        let keyBefore = store.key(for: page)
        let blank = try #require(await store.image(for: page))
        #expect(PixelReader(blank).isWhite(100, 200))

        notebook.setDrawing(lineDrawing(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 300, y: 400), width: 20), for: page.id)

        #expect(store.key(for: page) != keyBefore)
        let inked = try #require(await store.image(for: page))
        #expect(PixelReader(inked).isDark(100, 200))
        #expect(store.renderCount == 2)
    }

    @Test func rotatingAPageGivesAThumbnailOfTheTurnedShape() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let store = ThumbnailStore(notebook: notebook)
        let id = notebook.pages[0].id
        let before = try #require(await store.image(for: notebook.pages[0]))
        #expect(PixelReader(before).width == 298)

        try notebook.rotatePages([id], by: 90)

        let after = try #require(await store.image(for: notebook.pages[0]))
        #expect(PixelReader(after).width == 421 && PixelReader(after).height == 298)
    }

    @Test func aReopenedNotebookReusesThePicturesOnDisk() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[1]
        _ = await ThumbnailStore(notebook: notebook).image(for: page)
        let file = notebook.package.url.appending(path: "thumbnails/\(page.id.uuidString)-r0.jpg")
        #expect(await waitForFile(file))

        let reopened = try Notebook.open(notebook.package)
        let freshStore = ThumbnailStore(notebook: reopened)
        let image = await freshStore.image(for: reopened.pages[1])

        #expect(image != nil)
        #expect(freshStore.renderCount == 0)  // read from the file, not drawn
    }

    @Test func aPictureOlderThanTheSavedInkIsNotReused() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[1]
        _ = await ThumbnailStore(notebook: notebook).image(for: page)
        let file = notebook.package.url.appending(path: "thumbnails/\(page.id.uuidString)-r0.jpg")
        #expect(await waitForFile(file))
        try await Task.sleep(for: .milliseconds(50))
        notebook.setDrawing(lineDrawing(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 300, y: 400), width: 20), for: page.id)
        await notebook.saveChanges()  // the drawing file is now newer than the picture

        let reopened = try Notebook.open(notebook.package)
        let freshStore = ThumbnailStore(notebook: reopened)
        let image = try #require(await freshStore.image(for: reopened.pages[1]))

        #expect(freshStore.renderCount == 1)
        #expect(PixelReader(image).isDark(100, 200))
    }

    @Test func drawingAThumbnailDoesNotKeepThePagesInkInMemory() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0]
        notebook.setDrawing(sampleDrawing(), for: page.id)
        await notebook.saveChanges()
        notebook.evictDrawings(keeping: [])
        let store = ThumbnailStore(notebook: notebook)

        _ = await store.image(for: page)

        #expect(notebook.loadedPageIDs.isEmpty)
    }

    @Test func aPageThatIsGoneYieldsNoPicture() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let doomed = notebook.pages[0]
        try notebook.deletePages([doomed.id])
        let store = ThumbnailStore(notebook: notebook)

        #expect(await store.image(for: doomed) == nil)
    }
}

@MainActor
struct PageNavigatorTests {
    @Test func goingToAPageScrollsThereAndReportsIt() async throws {
        let folder = try TempFolder()
        let source = try makeLabeledPDF(in: folder.url, labels: ["P1", "P2", "P3", "P4", "P5"])
        let package = try NotebookPackage.importPDF(
            from: source, in: folder.url.appending(path: "library"), title: "T", coverColor: "#000000")
        let notebook = try Notebook.open(package)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        let pdfView = PDFView(frame: window.bounds)
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.document = notebook.document
        window.addSubview(pdfView)
        window.makeKeyAndVisible()
        let navigator = PageNavigator(notebook: notebook)
        navigator.attach(pdfView)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(navigator.currentPageID == notebook.pages[0].id)

        navigator.goTo(notebook.pages[3].id)
        try await Task.sleep(for: .milliseconds(500))

        #expect(navigator.currentPageID == notebook.pages[3].id)
        #expect(pdfView.currentPage.flatMap { notebook.pageID(for: $0) } == notebook.pages[3].id)
    }
}
