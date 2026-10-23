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

/// A detached tab (its notebook is being moved by the library) can be neither shown nor closed.
@MainActor
struct DetachedTabTests {
    @Test func aDetachedTabIgnoresSelectAndCloseAndThenFollows() async throws {
        let temp = try TempFolder()
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        let packages = [try makeNotebook(in: temp.url, title: "Moving"), try makeNotebook(in: temp.url, title: "Other")]
        for package in packages { try window.open(package) }
        window.showLibrary()
        let tab = window.tabs[0]

        let detached = try await window.detachTabs(under: packages[0].url)
        #expect(tab.isDetached)
        try window.select(tab.id)                // tapped during the action
        #expect(window.notebook == nil && !tab.isLoaded)
        #expect(await window.closeTab(tab.id) == false)
        #expect(window.tabs.count == 2)

        let newURL = temp.url.appending(path: "Moved.inkbook")
        try FileManager.default.moveItem(at: packages[0].url, to: newURL)
        window.reattach(detached, movedFrom: packages[0].url, to: newURL)

        #expect(!tab.isDetached)
        #expect(OpenNotebookRegistry.key(tab.url) == OpenNotebookRegistry.key(newURL))
        #expect(registry.owner(of: newURL)?.tab == tab.id)
        try window.select(tab.id)
        #expect(window.notebook?.meta.title == "Moving")
    }

    @Test func aTabClosedDuringTheActionClaimsNothing() async throws {
        let temp = try TempFolder()
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        let package = try makeNotebook(in: temp.url, title: "Moving")
        try window.open(package)
        window.showLibrary()
        let tab = window.tabs[0]
        let detached = try await window.detachTabs(under: package.url)
        tab.isDetached = false                   // as if it had been closed anyway
        #expect(await window.closeTab(tab.id))

        let newURL = temp.url.appending(path: "Moved.inkbook")
        window.reattach(detached, movedFrom: package.url, to: newURL)

        #expect(window.tabs.isEmpty)
        #expect(!registry.isOpen(at: newURL))
    }
}

/// The developer's report (2026-10-23): a notebook open in window 1 was moved from window 2's library.
@MainActor
struct OtherWindowMoveTests {
    @Test func movingFromAnotherWindowIsRefusedShownOrInBackground() async throws {
        for background in [false, true] {
            let temp = try TempFolder()
            let registry = OpenNotebookRegistry()
            let windowOne = WindowSession(registry: registry), windowTwo = WindowSession(registry: registry)
            let library = LibraryModel(location: LibraryLocation(root: temp.url), registry: registry)
            library.tabHost = windowTwo
            let folder = try library.operations.createFolder(named: "Archive", in: temp.url)
            let package = try makeNotebook(in: temp.url, title: "Open")
            try windowOne.open(package)
            if background { windowOne.showLibrary() }

            await library.move(package.url, into: folder)
            #expect(library.errorMessage == LibraryError.openInAnotherWindow.errorDescription)
            library.errorMessage = nil
            await library.moveSelection(into: folder)  // nothing selected: no change
            library.toggleSelection(package.url)
            await library.moveSelection(into: folder)

            #expect(FileManager.default.fileExists(atPath: package.url.path), "moved although open (background: \(background))")
        }
    }
}

/// Renaming from the tab's menu (2026-10-23), also for the shown tab.
@MainActor
struct RenameTabTests {
    @Test func theShownTabIsRenamedAndShownAgain() async throws {
        // The real Documents folder is used by renameTab; work on a notebook created there.
        let package = try makeNotebook(in: LibraryLocation.documents.root, title: "Rename Me \(UUID().uuidString.prefix(6))")
        let renamed = "Renamed \(UUID().uuidString.prefix(6))"
        let registry = OpenNotebookRegistry()
        let window = WindowSession(registry: registry)
        try window.open(package)
        let tab = window.tabs[0]

        try await window.renameTab(tab.id, to: renamed)

        #expect(tab.title == renamed)
        #expect(window.activeTab === tab)
        #expect(window.notebook?.meta.title == renamed)
        #expect(registry.owner(of: tab.url)?.tab == tab.id)
        #expect(!FileManager.default.fileExists(atPath: package.url.path))
        await window.close()
        try? FileManager.default.removeItem(at: tab.url)
    }
}
