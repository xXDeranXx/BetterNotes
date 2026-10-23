import Foundation
import Testing
@testable import BetterNotes

/// Tabs step 5: tabs come back after a launch.
@MainActor
struct TabRestoreTests {
    @Test func tabsRoundTripReleasedWithTheShownOneAndPositions() throws {
        let temp = try TempFolder()
        let folder = temp.url.appending(path: "Uni")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let packages = [try makeNotebook(in: folder, title: "A"), try makeNotebook(in: temp.url, title: "B")]
        let before = WindowSession(registry: OpenNotebookRegistry())
        for package in packages { try before.open(package) }
        try before.select(before.tabs[0].id)
        let page = before.notebook!.pages[0].id
        before.tabs[0].position = TabPosition(pageID: page, point: CGPoint(x: 10, y: 700), zoom: 2)

        let saved = before.savedTabs(root: temp.url)
        #expect(saved.tabs.map(\.relativePath) == ["Uni/A.inkbook", "B.inkbook"])
        #expect(saved.activeIndex == 0)
        let data = try JSONEncoder().encode(saved)

        let registry = OpenNotebookRegistry()
        let after = WindowSession(registry: registry)
        let (skipped, shown) = after.restoreTabs(try JSONDecoder().decode(SavedTabs.self, from: data), root: temp.url)

        #expect(skipped == 0)
        #expect(after.tabs.map(\.title) == ["A", "B"])
        #expect(after.tabs.allSatisfy { !$0.isLoaded })  // shown only once the window is active
        #expect(shown == after.tabs[0].id)
        try after.select(try #require(shown))
        #expect(after.activeTab === after.tabs[0])
        #expect(after.tabs[0].isLoaded && !after.tabs[1].isLoaded)  // only the shown one loads
        #expect(after.tabs[0].position?.zoom == 2)
        #expect(registry.owner(of: packages[1].url)?.tab == after.tabs[1].id)
    }

    @Test func theLibraryStaysShownWhenItWasShown() throws {
        let temp = try TempFolder()
        let package = try makeNotebook(in: temp.url, title: "A")
        let before = WindowSession(registry: OpenNotebookRegistry())
        try before.open(package)
        before.showLibrary()

        let after = WindowSession(registry: OpenNotebookRegistry())
        let (_, shown) = after.restoreTabs(before.savedTabs(root: temp.url), root: temp.url)

        #expect(after.tabs.count == 1)
        #expect(shown == nil)
        #expect(after.notebook == nil)
    }

    @Test func aMovedNotebookIsFoundByItsID() throws {
        let temp = try TempFolder()
        let package = try makeNotebook(in: temp.url, title: "A")
        let before = WindowSession(registry: OpenNotebookRegistry())
        try before.open(package)
        let saved = before.savedTabs(root: temp.url)
        before.showLibrary()
        releaseClaims(before)
        let archive = temp.url.appending(path: "Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: package.url, to: archive.appending(path: "A.inkbook"))  // in the Files app

        let after = WindowSession(registry: OpenNotebookRegistry())
        #expect(after.restoreTabs(saved, root: temp.url).skipped == 0)
        #expect(after.tabs.first?.url.path.hasSuffix("Archive/A.inkbook") == true)
    }

    @Test func goneOrTakenNotebooksAreCounted() throws {
        let temp = try TempFolder()
        let packages = [try makeNotebook(in: temp.url, title: "Gone"), try makeNotebook(in: temp.url, title: "Taken"),
                        try makeNotebook(in: temp.url, title: "Fine")]
        let before = WindowSession(registry: OpenNotebookRegistry())
        for package in packages { try before.open(package) }
        let saved = before.savedTabs(root: temp.url)
        try FileManager.default.removeItem(at: packages[0].url)
        let registry = OpenNotebookRegistry()
        let other = WindowSession(registry: registry)
        try other.open(packages[1])

        let after = WindowSession(registry: registry)
        let (skipped, shown) = after.restoreTabs(saved, root: temp.url)
        #expect(skipped == 2)
        #expect(after.tabs.map(\.title) == ["Fine"])
        #expect(shown == after.tabs[0].id)  // it was the shown one
    }

    @Test func pathsOutsideTheRootAreNotRelative() {
        let root = URL(filePath: "/tmp/Lib")
        #expect(SavedTabs.relativePath(of: URL(filePath: "/tmp/Lib/Uni/A.inkbook"), in: root) == "Uni/A.inkbook")
        #expect(SavedTabs.relativePath(of: URL(filePath: "/tmp/Library/A.inkbook"), in: root) == nil)
    }

    /// The first window releases its claim (as if the app had quit).
    private func releaseClaims(_ window: WindowSession) {
        window.registry.releaseAll(ownedBy: window.windowID)
    }
}

/// Tabs step 5: where the tabs are kept between launches.
@MainActor
struct TabStoreTests {
    private func defaults() -> UserDefaults {
        let name = "TabStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func tabs(_ path: String) -> SavedTabs {
        SavedTabs(tabs: [SavedTabs.Entry(relativePath: path, notebookID: nil, position: nil)], activeIndex: 0)
    }

    @Test func aWindowGetsItsOwnTabsBack() {
        let store = defaults()
        TabStore.startNewLaunch()
        TabStore.save(tabs("A.inkbook"), windowKey: "one", defaults: store)
        TabStore.save(tabs("B.inkbook"), windowKey: "two", now: .now + 10, defaults: store)

        TabStore.startNewLaunch()
        let loaded = TabStore.load(windowKey: "one", defaults: store)
        #expect(loaded.key == "one")
        #expect(loaded.tabs == tabs("A.inkbook"))  // its own, not the newest
    }

    @Test func theFirstNewWindowTakesTheNewestTabsAndLaterOnesStartEmpty() {
        let store = defaults()
        TabStore.save(tabs("Old.inkbook"), windowKey: "one", now: .now, defaults: store)
        TabStore.save(tabs("New.inkbook"), windowKey: "two", now: .now + 10, defaults: store)

        TabStore.startNewLaunch()
        let first = TabStore.load(windowKey: nil, defaults: store)  // the app was swiped away
        #expect(first.key == "two")
        #expect(first.tabs == tabs("New.inkbook"))
        let second = TabStore.load(windowKey: nil, defaults: store)
        #expect(second.tabs == nil)
        #expect(second.key != "two")
    }

    @Test func onlyTheNewestWindowsAreKept() {
        let store = defaults()
        for index in 0..<15 {
            TabStore.save(tabs("\(index).inkbook"), windowKey: "w\(index)", now: Date(timeIntervalSince1970: Double(index)), defaults: store)
        }
        TabStore.startNewLaunch()
        // w0 was dropped, so its window counts as new and (being first) takes the newest tabs.
        #expect(TabStore.load(windowKey: "w0", defaults: store).key == "w14")
        TabStore.startNewLaunch()
        #expect(TabStore.load(windowKey: "w14", defaults: store).tabs == tabs("14.inkbook"))
    }
}
