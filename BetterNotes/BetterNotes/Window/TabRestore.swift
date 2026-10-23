import Foundation

/// A window's tabs as they are kept between launches (tabs step 5), in the window's
/// `@SceneStorage`, which iPadOS hands back when it restores that window.
///
/// Paths are stored **relative to the library root**, plus the notebook's id: the app's
/// container path changes when the app is installed again (every 7 days with the free
/// account), so an absolute path would break every week. A notebook that was moved in the
/// Files app is found again by its id.
nonisolated struct SavedTabs: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var relativePath: String
        var notebookID: UUID?
        var position: TabPosition?
    }

    var tabs: [Entry] = []
    /// Index of the shown tab; nil when the library was shown.
    var activeIndex: Int?

    /// A notebook found again, with what the tab remembered.
    struct Restored: Equatable, Sendable {
        var url: URL
        var entry: Entry
        var wasActive: Bool
    }

    /// Finds each saved notebook: at its path if it is still the same notebook there, otherwise
    /// anywhere in the library by its id. Notebooks that are gone are left out and counted.
    func resolve(in root: URL) -> (found: [Restored], missing: Int) {
        var byID: [UUID: URL]?  // the library is scanned only if a notebook moved
        var found: [Restored] = []
        var missing = 0
        for (index, entry) in tabs.enumerated() {
            let atPath = root.appending(path: entry.relativePath)
            var url: URL?
            if Self.notebookID(at: atPath) == entry.notebookID, FileManager.default.fileExists(atPath: atPath.path) {
                url = atPath
            } else if let id = entry.notebookID {
                if byID == nil {
                    byID = Dictionary(
                        LibraryScanner.allNotebooks(under: root).compactMap { s in s.notebookID.map { ($0, s.url) } },
                        uniquingKeysWith: { first, _ in first })
                }
                url = byID?[id]
            }
            if let url {
                found.append(Restored(url: url, entry: entry, wasActive: index == activeIndex))
            } else {
                missing += 1
            }
        }
        return (found, missing)
    }

    /// `url` relative to `root`, or nil if it is not inside it.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let path = OpenNotebookRegistry.key(url).path, rootPath = OpenNotebookRegistry.key(root).path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func notebookID(at url: URL) -> UUID? {
        try? NotebookPackage(url: url).readMeta().id
    }
}

/// Where the windows' tabs are kept: in `UserDefaults`, written on every change, one entry
/// per window key. The window's own `@SceneStorage` holds only its key: SwiftUI writes scene
/// storage to disk only now and then, so after the app was killed it held tabs from minutes
/// before (seen in `TabsUITests`). When the app is swiped away in the app switcher iPadOS
/// forgets its windows, keys included; then the first window of the launch takes the newest
/// entry.
@MainActor
enum TabStore {
    private struct Stored: Codable {
        var tabs: SavedTabs
        var savedAt: Date
    }

    private static let defaultsKey = "tabsByWindow"
    /// Old entries of windows that are gone are dropped beyond this many.
    private static let keptWindows = 10
    private static var isFirstWindowOfLaunch = true

    /// The tabs for a window with `windowKey` (nil for a window that has none yet), and the key
    /// the window uses from now on.
    static func load(windowKey: String?, defaults: UserDefaults = .standard) -> (key: String, tabs: SavedTabs?) {
        let entries = read(defaults)
        let isFirst = isFirstWindowOfLaunch
        isFirstWindowOfLaunch = false
        if let windowKey, let own = entries[windowKey] { return (windowKey, own.tabs) }
        if isFirst, let newest = entries.max(by: { $0.value.savedAt < $1.value.savedAt }) {
            return (newest.key, newest.value.tabs)
        }
        return (windowKey ?? UUID().uuidString, nil)
    }

    static func save(_ tabs: SavedTabs, windowKey: String, now: Date = .now, defaults: UserDefaults = .standard) {
        var entries = read(defaults)
        entries[windowKey] = Stored(tabs: tabs, savedAt: now)
        if entries.count > keptWindows {
            let newest = entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(keptWindows)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: defaultsKey)
    }

    /// For tests: the next `load` counts as the first window of a launch again.
    static func startNewLaunch() { isFirstWindowOfLaunch = true }

    private static func read(_ defaults: UserDefaults) -> [String: Stored] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Stored].self, from: data)) ?? [:]
    }
}

extension WindowSession {
    /// What to keep for the next launch.
    func savedTabs(root: URL) -> SavedTabs {
        var saved = SavedTabs()
        for tab in tabs {
            guard let path = SavedTabs.relativePath(of: tab.url, in: root) else { continue }
            if tab.id == activeTabID { saved.activeIndex = saved.tabs.count }
            saved.tabs.append(SavedTabs.Entry(relativePath: path, notebookID: tab.notebookID, position: tab.position))
        }
        return saved
    }

    /// Brings the tabs back after a launch, all released (fast). Only for a window without
    /// tabs. Returns how many could not be restored (gone, or open in another window
    /// meanwhile) and the tab that was shown, which the caller shows with `select` once the
    /// window is active: PencilKit did not draw the ink of a canvas built while the window was
    /// still starting up (seen in `TabsUITests` after a relaunch).
    func restoreTabs(_ saved: SavedTabs, root: URL) -> (skipped: Int, shown: UUID?) {
        guard tabs.isEmpty else { return (0, nil) }
        let (found, missing) = saved.resolve(in: root)
        var skipped = missing
        var active: UUID?
        for item in found {
            let tab = NotebookTab(releasedAt: item.url, notebookID: item.entry.notebookID)
            tab.position = item.entry.position
            guard registry.claim(item.url, by: NotebookOwner(window: windowID, tab: tab.id)) else {
                skipped += 1
                continue
            }
            appendRestored(tab)
            if item.wasActive { active = tab.id }
        }
        return (skipped, active)
    }
}
