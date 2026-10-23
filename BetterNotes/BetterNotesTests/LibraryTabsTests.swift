import Foundation
import PencilKit
import Testing
@testable import BetterNotes

/// Tabs step 4: library actions on notebooks in this window's background tabs.
@MainActor
struct LibraryTabsTests {
    private struct Setup {
        let temp: TempFolder
        let registry: OpenNotebookRegistry
        let window: WindowSession
        let model: LibraryModel
    }

    private func setup() throws -> Setup {
        let temp = try TempFolder()
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        let model = LibraryModel(location: LibraryLocation(root: temp.url), registry: registry)
        model.tabHost = window
        return Setup(temp: temp, registry: registry, window: window, model: model)
    }

    /// Opens the notebooks as tabs and goes back to the library, so all of them are background tabs.
    private func openInBackground(_ packages: [NotebookPackage], in window: WindowSession) throws {
        for package in packages { try window.open(package) }
        window.showLibrary()
    }

    @Test func renamingABackgroundTabsNotebookMovesTheTabAlong() async throws {
        let s = try setup()
        let package = try makeNotebook(in: s.temp.url, title: "Old")
        try openInBackground([package], in: s.window)
        let tab = try #require(s.window.tabs.first)

        await s.model.rename(package.url, to: "New")

        #expect(s.model.errorMessage == nil)
        #expect(tab.url.lastPathComponent == "New.inkbook")
        #expect(tab.title == "New")
        #expect(!tab.isLoaded)
        #expect(s.registry.owner(of: tab.url)?.tab == tab.id)
        #expect(!s.registry.isOpen(at: package.url))
        try s.window.select(tab.id)  // opens at the new place
        #expect(s.window.notebook?.meta.title == "New")
    }

    @Test func movingAFolderMovesTheTabsInsideIt() async throws {
        let s = try setup()
        let folder = try s.model.operations.createFolder(named: "Uni", in: s.temp.url)
        let target = try s.model.operations.createFolder(named: "Archive", in: s.temp.url)
        let package = try makeNotebook(in: folder, title: "Lecture")
        try openInBackground([package], in: s.window)
        let tab = try #require(s.window.tabs.first)

        await s.model.move(folder, into: target)

        #expect(s.model.errorMessage == nil)
        #expect(tab.url.path.hasSuffix("Archive/Uni/Lecture.inkbook"))
        #expect(FileManager.default.fileExists(atPath: tab.url.path))
        #expect(s.registry.owner(of: tab.url)?.tab == tab.id)
    }

    @Test func trashingClosesTheTab() async throws {
        let s = try setup()
        let packages = [try makeNotebook(in: s.temp.url, title: "Gone"), try makeNotebook(in: s.temp.url, title: "Stays")]
        try openInBackground(packages, in: s.window)

        await s.model.trash(packages[0].url)

        #expect(s.model.errorMessage == nil)
        #expect(s.window.tabs.map(\.title) == ["Stays"])
        #expect(!s.registry.isOpen(at: packages[0].url))
    }

    @Test func theShownTabIsStillLocked() async throws {
        let s = try setup()
        let package = try makeNotebook(in: s.temp.url, title: "Shown")
        try s.window.open(package)  // shown, not in the background

        await s.model.rename(package.url, to: "Other")

        #expect(s.model.errorMessage == LibraryError.isOpen.errorDescription)
        #expect(s.window.tabs[0].url == package.url)
        #expect(s.window.tabs[0].isLoaded)
    }

    @Test func aNotebookInAnotherWindowIsRefused() async throws {
        let s = try setup()
        let package = try makeNotebook(in: s.temp.url, title: "Elsewhere")
        let other = WindowSession(registry: s.registry)
        try other.open(package)
        other.showLibrary()

        await s.model.rename(package.url, to: "Other")

        #expect(s.model.errorMessage == LibraryError.openInAnotherWindow.errorDescription)
        #expect(other.tabs[0].url == package.url)
        #expect(FileManager.default.fileExists(atPath: package.url.path))
    }

    @Test func aFailedActionLeavesTheTabWhereItWas() async throws {
        let s = try setup()
        let folder = try s.model.operations.createFolder(named: "Uni", in: s.temp.url)
        let package = try makeNotebook(in: folder, title: "Lecture")
        try openInBackground([package], in: s.window)
        let tab = try #require(s.window.tabs.first)

        await s.model.move(folder, into: folder)  // into itself: refused by the file layer

        #expect(s.model.errorMessage == LibraryError.moveIntoItself.errorDescription)
        #expect(OpenNotebookRegistry.key(tab.url) == OpenNotebookRegistry.key(package.url))
        #expect(s.registry.owner(of: package.url)?.tab == tab.id)  // claimed again
    }

    @Test func aTabThatCannotBeSavedBlocksTheAction() async throws {
        let s = try setup()
        let package = try makeNotebook(in: s.temp.url, title: "Unsaved")
        try s.window.open(package)
        let notebook = try #require(s.window.notebook)
        notebook.autosaveDelay = .seconds(60)
        notebook.setDrawing(sampleDrawing(), for: notebook.pages[0].id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.drawingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.drawingsURL.path) }
        s.window.showLibrary()

        await s.model.rename(package.url, to: "Other")

        #expect(s.model.errorMessage == LibraryError.tabNotSaved("Unsaved").errorDescription)
        #expect(s.window.tabs[0].isLoaded)  // the ink is still in memory
        #expect(FileManager.default.fileExists(atPath: package.url.path))
        #expect(s.registry.owner(of: package.url)?.tab == s.window.tabs[0].id)
    }

    @Test func rebaseFollowsAFolderMove() {
        let old = URL(filePath: "/tmp/Lib/Uni")
        let new = URL(filePath: "/tmp/Lib/Archive/Uni")
        #expect(WindowSession.rebase(URL(filePath: "/tmp/Lib/Uni/A.inkbook"), from: old, to: new).path == "/tmp/Lib/Archive/Uni/A.inkbook")
        #expect(WindowSession.rebase(old, from: old, to: new) == new)
        #expect(WindowSession.rebase(URL(filePath: "/tmp/Lib/Unix/A.inkbook"), from: old, to: new).path == "/tmp/Lib/Unix/A.inkbook")
    }
}
