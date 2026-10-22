import Foundation
import PencilKit
import Testing
@testable import BetterNotes

/// Polls until `condition` is true, for things that happen "soon" (autosave).
@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
struct AutosaveTests {
    private func makeOpenNotebook(in folder: TempFolder, pageCount: Int = 2) throws -> Notebook {
        let package = try makeNotebook(in: folder.url)
        var meta = try package.readMeta()
        while meta.pages.count < pageCount {
            meta.pages.append(PageMeta(template: .lined, size: .a4Portrait))
        }
        try package.writeMeta(meta)
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .milliseconds(50)
        return notebook
    }

    private func drawingFiles(of notebook: Notebook) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: notebook.package.drawingsURL.path).sorted()
    }

    @Test func savedInkSurvivesReopening() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)

        await notebook.saveChanges()

        #expect(notebook.dirtyPageIDs.isEmpty)
        #expect(notebook.saveError == nil)
        let reopened = try Notebook.open(notebook.package)  // like force-quit and relaunch
        let stroke = try #require(reopened.drawing(for: page).strokes.first)
        #expect(stroke.path.last?.location == CGPoint(x: 100, y: 80))
    }

    @Test func onlyChangedPagesAreWritten() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder, pageCount: 3)
        notebook.setDrawing(sampleDrawing(), for: notebook.pages[1].id)

        await notebook.saveChanges()

        #expect(try drawingFiles(of: notebook) == ["\(notebook.pages[1].id.uuidString).drawing"])
    }

    @Test func savingWithNothingChangedWritesNothing() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let before = try Data(contentsOf: notebook.package.metaURL)

        await notebook.saveChanges()

        #expect(try Data(contentsOf: notebook.package.metaURL) == before)
        #expect(try drawingFiles(of: notebook).isEmpty)
    }

    @Test func savingUpdatesTheModifiedDateInMeta() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        // meta.json stores whole seconds, so start from a clearly old date instead of "now".
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        var meta = try package.readMeta()
        meta.createdAt = longAgo
        meta.updatedAt = longAgo
        try package.writeMeta(meta)
        let notebook = try Notebook.open(package)
        notebook.setDrawing(sampleDrawing(), for: notebook.pages[0].id)

        await notebook.saveChanges()

        let saved = try package.readMeta()
        #expect(saved.updatedAt > longAgo)
        #expect(saved.createdAt == longAgo)  // only the modified date changes
    }

    @Test func autosaveWritesAboutTwoSecondsAfterTheLastChange() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        let page = notebook.pages[0].id

        notebook.setDrawing(sampleDrawing(offset: 0), for: page)
        notebook.setDrawing(sampleDrawing(offset: 7), for: page)  // a second stroke restarts the wait
        #expect(try drawingFiles(of: notebook).isEmpty)  // not written yet

        #expect(await waitUntil { notebook.dirtyPageIDs.isEmpty })
        let saved = try #require(try Notebook.open(notebook.package).drawing(for: page).strokes.first)
        #expect(saved.path.last?.location == CGPoint(x: 107, y: 80))  // the latest version
    }

    @Test func theDefaultAutosaveDelayIsTwoSeconds() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)

        #expect(try Notebook.open(package).autosaveDelay == .seconds(2))
    }

    @Test func aStrokeAddedDuringASaveIsNotLost() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        notebook.autosaveDelay = .seconds(60)  // only explicit saves in this test
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(offset: 0), for: page)
        // In the middle of the first save, the user adds another stroke.
        notebook.saveHook = { [weak notebook] in
            await MainActor.run { notebook?.setDrawing(sampleDrawing(offset: 50), for: page) }
        }

        await notebook.saveChanges()

        #expect(notebook.dirtyPageIDs == [page])  // the newer version is still waiting
        notebook.saveHook = nil
        await notebook.saveChanges()
        #expect(notebook.dirtyPageIDs.isEmpty)
        let saved = try #require(try Notebook.open(notebook.package).drawing(for: page).strokes.first)
        #expect(saved.path.last?.location == CGPoint(x: 150, y: 80))
    }

    @Test func aFailedSaveKeepsThePageDirtyShowsAnErrorAndRetryWorks() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        notebook.autosaveDelay = .seconds(60)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)
        let drawings = notebook.package.drawingsURL
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: drawings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drawings.path) }

        await notebook.saveChanges()

        #expect(notebook.dirtyPageIDs == [page])
        #expect(notebook.saveError != nil)
        #expect(notebook.drawing(for: page).strokes.count == 1)  // still in memory

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drawings.path)
        await notebook.saveChanges()  // Retry
        #expect(notebook.dirtyPageIDs.isEmpty)
        #expect(notebook.saveError == nil)
        #expect(try Notebook.open(notebook.package).drawing(for: page).strokes.count == 1)
    }

    @Test func anUnreadableDrawingFileIsCopiedAsideBeforeItIsReplaced() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let page = try package.readMeta().pages[0].id
        let garbage = Data("maybe recoverable by hand".utf8)
        try garbage.write(to: package.drawingURL(for: page))
        let notebook = try Notebook.open(package)
        notebook.autosaveDelay = .seconds(60)
        #expect(notebook.drawing(for: page).strokes.isEmpty)
        #expect(notebook.unreadablePageIDs == [page])

        notebook.setDrawing(sampleDrawing(), for: page)
        await notebook.saveChanges()

        let copy = package.drawingsURL.appending(path: "\(page.uuidString).drawing.unreadable")
        #expect(try Data(contentsOf: copy) == garbage)  // the old bytes survive
        #expect(try Notebook.open(package).drawing(for: page).strokes.count == 1)  // the new ink is saved
        #expect(notebook.unreadablePageIDs.isEmpty)
    }

    @Test func aSecondUnreadableCopyNeverOverwritesTheFirst() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let page = UUID()
        try Data("first".utf8).write(to: package.drawingURL(for: page))
        try package.preserveUnreadableDrawing(for: page)
        try Data("second".utf8).write(to: package.drawingURL(for: page))

        try package.preserveUnreadableDrawing(for: page)

        let first = package.drawingsURL.appending(path: "\(page.uuidString).drawing.unreadable")
        let second = package.drawingsURL.appending(path: "\(page.uuidString).drawing.unreadable-2")
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test func aPageIsSavedWhenItsCanvasLeavesTheScreen() async throws {
        let folder = try TempFolder()
        let notebook = try makeOpenNotebook(in: folder)
        notebook.autosaveDelay = .seconds(60)
        let coordinator = EditorCoordinator(notebook: notebook)
        let overlay = PageOverlayView(pageID: notebook.pages[0].id)
        overlay.canvas.delegate = coordinator
        coordinator.overlayDidAppear(overlay)
        notebook.setDrawing(sampleDrawing(), for: overlay.pageID)

        coordinator.overlayDidDisappear(overlay)

        #expect(await waitUntil { notebook.dirtyPageIDs.isEmpty })
    }
}

@MainActor
struct WindowSaveAndRegistryTests {
    @Test func theSameNotebookCannotBeOpenInTwoWindows() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(package)

        #expect(throws: NotebookError.alreadyOpen) { try windowTwo.open(package) }
        #expect(windowTwo.notebook == nil)
    }

    @Test func theSameFolderReachedThroughAnotherPathIsStillTheSameNotebook() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        #expect(registry.claim(package.url))

        let roundabout = package.url.deletingLastPathComponent()
            .appending(path: "x/../\(package.url.lastPathComponent)")

        #expect(!registry.claim(roundabout))
    }

    @Test func closingFreesTheNotebookForAnotherWindow() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(package)

        await windowOne.close()

        #expect(windowOne.notebook == nil)
        try windowTwo.open(package)
        #expect(windowTwo.notebook != nil)
    }

    @Test func aWindowThatSimplyGoesAwayFreesItsNotebook() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        var window: WindowSession? = WindowSession(registry: registry)
        try window?.open(package)

        window = nil  // the user swipes the window away

        #expect(registry.claim(package.url))
    }

    @Test func aFailedOpenDoesNotKeepTheNotebookClaimed() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        try Data("{ not json".utf8).write(to: package.metaURL)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)

        #expect(throws: (any Error).self) { try window.open(package) }

        #expect(registry.claim(package.url))
    }

    @Test func closingSavesFirst() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let window = WindowSession(registry: OpenNotebookRegistry())
        try window.open(package)
        let notebook = try #require(window.notebook)
        notebook.autosaveDelay = .seconds(60)
        let page = notebook.pages[0].id
        notebook.setDrawing(sampleDrawing(), for: page)

        await window.close()

        #expect(window.notebook == nil)
        #expect(try Notebook.open(package).drawing(for: page).strokes.count == 1)
    }

    @Test func aNotebookThatCannotBeSavedStaysOpen() async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let window = WindowSession(registry: OpenNotebookRegistry())
        try window.open(package)
        let notebook = try #require(window.notebook)
        notebook.autosaveDelay = .seconds(60)
        notebook.setDrawing(sampleDrawing(), for: notebook.pages[0].id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.drawingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.drawingsURL.path) }

        await window.close()

        #expect(window.notebook != nil)  // closing would have thrown the ink away
        #expect(notebook.saveError != nil)
    }
}
