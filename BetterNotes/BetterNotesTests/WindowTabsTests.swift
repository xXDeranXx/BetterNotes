import Foundation
import PencilKit
import Testing
@testable import BetterNotes

/// Tabs step 2: a window holds several notebooks as tabs (see `docs/DECISIONS.md`, "Tabs").
@MainActor
struct WindowTabsTests {
    private func notebooks(_ count: Int, in folder: TempFolder) throws -> [NotebookPackage] {
        try (1...count).map { try makeNotebook(in: folder.url, title: "Notebook \($0)") }
    }

    @Test func openingAnotherNotebookAddsATabAndKeepsTheFirst() throws {
        let folder = try TempFolder()
        let packages = try notebooks(2, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())

        try window.open(packages[0])
        try window.open(packages[1])

        #expect(window.tabs.count == 2)
        #expect(window.activeTab === window.tabs[1])
        #expect(window.notebook?.package.url == packages[1].url)
        #expect(window.tabs[0].isLoaded)
        #expect(window.tabs.map(\.title) == ["Notebook 1", "Notebook 2"])
    }

    @Test func openingANotebookThatHasATabSelectsIt() throws {
        let folder = try TempFolder()
        let packages = try notebooks(2, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())
        try window.open(packages[0])
        try window.open(packages[1])

        try window.open(NotebookPackage(url: packages[0].url))

        #expect(window.tabs.count == 2)
        #expect(window.activeTab === window.tabs[0])
    }

    @Test func aNotebookInAnotherWindowIsRefused() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
        try windowOne.open(package)

        #expect(throws: NotebookError.openInOtherWindow) { try windowTwo.open(package) }  // window one comes forward (M9)
        #expect(windowTwo.tabs.isEmpty)
        #expect(registry.owner(of: package.url)?.window == windowOne.windowID)
    }

    @Test func undoSurvivesSwitchingTabs() throws {
        let folder = try TempFolder()
        let packages = try notebooks(2, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())
        try window.open(packages[0])
        let first = try #require(window.notebook)
        first.autosaveDelay = .seconds(60)
        let page = first.pages[0].id
        first.setDrawing(sampleDrawing(), for: page)

        try window.open(packages[1])
        try window.select(window.tabs[0].id)

        #expect(window.notebook === first)  // the same model, not a reloaded one
        #expect(first.canUndo)
        first.undoManager.undo()
        #expect(first.drawing(for: page).strokes.isEmpty)
    }

    @Test func tabsBeyondTheLimitAreSavedAndReleasedButStayOpen() async throws {
        let folder = try TempFolder()
        let limit = WindowSession.loadedTabLimit
        let packages = try notebooks(limit + 1, in: folder)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        try window.open(packages[0])
        let oldest = try #require(window.notebook)
        oldest.autosaveDelay = .seconds(60)
        let page = oldest.pages[0].id
        oldest.setDrawing(sampleDrawing(), for: page)

        for package in packages.dropFirst() { try window.open(package) }
        await window.releaseTask?.value

        #expect(!window.tabs[0].isLoaded)
        #expect(window.tabs.dropFirst().allSatisfy { $0.isLoaded })
        #expect(window.tabs.filter(\.isLoaded).count == limit)
        #expect(registry.owner(of: packages[0].url)?.tab == window.tabs[0].id)  // still claimed
        #expect(try Notebook.open(packages[0]).drawing(for: page).strokes.count == 1)  // saved before release

        // Selecting it loads the notebook again, with its ink.
        try window.select(window.tabs[0].id)
        #expect(window.notebook?.drawing(for: page).strokes.count == 1)
        await window.releaseTask?.value
        #expect(window.tabs.filter(\.isLoaded).count == limit)
        #expect(!window.tabs[1].isLoaded)  // now the least recently used one
    }

    @Test func aTabThatCannotBeSavedStaysLoaded() async throws {
        let folder = try TempFolder()
        let limit = WindowSession.loadedTabLimit
        let packages = try notebooks(limit + 1, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())
        try window.open(packages[0])
        let oldest = try #require(window.notebook)
        oldest.autosaveDelay = .seconds(60)
        oldest.setDrawing(sampleDrawing(), for: oldest.pages[0].id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packages[0].drawingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packages[0].drawingsURL.path) }

        for package in packages.dropFirst() { try window.open(package) }
        await window.releaseTask?.value

        #expect(window.tabs[0].isLoaded)  // over the limit, but the ink is not thrown away
        #expect(oldest.hasUnsavedChanges)
    }

    @Test func libraryKeepsTheTabs() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        try window.open(package)

        window.showLibrary()

        #expect(window.notebook == nil)
        #expect(window.tabs.count == 1 && window.tabs[0].isLoaded)
        #expect(registry.isOpen(at: package.url))
    }

    @Test func closingTheShownTabShowsItsNeighbourThenTheLibrary() async throws {
        let folder = try TempFolder()
        let packages = try notebooks(3, in: folder)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        for package in packages { try window.open(package) }
        try window.select(window.tabs[1].id)

        #expect(await window.closeTab(window.tabs[1].id))
        #expect(window.notebook?.package.url == packages[2].url)  // the one on the right
        #expect(!registry.isOpen(at: packages[1].url))

        await window.close()
        #expect(window.notebook?.package.url == packages[0].url)  // the last one left
        await window.close()
        #expect(window.tabs.isEmpty && window.notebook == nil)
    }

    @Test func closingABackgroundTabKeepsTheShownOne() async throws {
        let folder = try TempFolder()
        let packages = try notebooks(2, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())
        for package in packages { try window.open(package) }

        await window.closeTab(window.tabs[0].id)

        #expect(window.tabs.count == 1)
        #expect(window.notebook?.package.url == packages[1].url)
    }

    @Test func closeOtherTabsKeepsOnlyOne() async throws {
        let folder = try TempFolder()
        let packages = try notebooks(4, in: folder)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        for package in packages { try window.open(package) }
        let kept = window.tabs[1].id

        await window.closeOtherTabs(keeping: kept)

        #expect(window.tabs.map(\.id) == [kept])
        #expect(packages.filter { registry.isOpen(at: $0.url) }.map(\.url) == [packages[1].url])
    }

    @Test func movingATabReordersTheStrip() throws {
        let folder = try TempFolder()
        let packages = try notebooks(3, in: folder)
        let window = WindowSession(registry: OpenNotebookRegistry())
        for package in packages { try window.open(package) }
        let ids = window.tabs.map(\.id)

        window.moveTab(ids[2], to: 0)
        #expect(window.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
        window.moveTab(ids[2], to: 99)
        #expect(window.tabs.map(\.id) == ids)
    }

    @Test func aReleasedTabWhoseNotebookIsGoneIsRemovedWithAnError() async throws {
        let folder = try TempFolder()
        let limit = WindowSession.loadedTabLimit
        let packages = try notebooks(limit + 1, in: folder)
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        for package in packages { try window.open(package) }
        await window.releaseTask?.value
        try FileManager.default.removeItem(at: packages[0].url)  // deleted in the Files app

        #expect(throws: (any Error).self) { try window.select(window.tabs[0].id) }

        #expect(window.tabs.count == limit)
        #expect(!registry.isOpen(at: packages[0].url))
        #expect(window.notebook?.package.url == packages[limit].url)  // still showing the last one
    }

    @Test func aWindowThatGoesAwayFreesAllItsTabs() throws {
        let folder = try TempFolder()
        let packages = try notebooks(2, in: folder)
        let registry = OpenNotebookRegistry()
        var window: WindowSession? = WindowSession(registry: registry)
        for package in packages { try window?.open(package) }

        window = nil

        #expect(packages.allSatisfy { !registry.isOpen(at: $0.url) })
    }
}
