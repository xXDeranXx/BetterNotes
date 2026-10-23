import Foundation
import Synchronization

/// Who has a notebook open: a tab in a window. Each `WindowSession` has its own `window` id,
/// and each of its tabs its own `tab` id.
nonisolated struct NotebookOwner: Hashable, Sendable {
    let window: UUID
    let tab: UUID
}

/// Remembers which notebooks are open, and where (SPEC, "Data safety": a notebook is open in
/// at most one tab of one window). Two tabs editing the same notebook would each hold their
/// own model and overwrite each other's drawing files.
///
/// This is the one piece of shared state between windows, because it is exactly the
/// coordination between them. Window state (the tabs, their models, their undo histories)
/// stays in each window's `WindowSession`. Knowing the owner lets a window select the tab
/// that already has a notebook, and (milestone 9) bring another window forward.
nonisolated final class OpenNotebookRegistry: Sendable {
    static let shared = OpenNotebookRegistry()

    /// The open notebooks and their owners. A claim without an owner is a short one by code
    /// that is not a tab (moving pages into a notebook, see `PageTransfer`).
    private let openNotebooks = Mutex<[URL: NotebookOwner?]>([:])

    /// `true` if the notebook was free and is now claimed; `false` if it is open already.
    func claim(_ url: URL, by owner: NotebookOwner? = nil) -> Bool {
        openNotebooks.withLock { open in
            let key = Self.key(url)
            guard open[key] == nil else { return false }
            open[key] = .some(owner)
            return true
        }
    }

    /// The tab that has this notebook open; nil if it is not open, or claimed without an owner.
    func owner(of url: URL) -> NotebookOwner? {
        openNotebooks.withLock { $0[Self.key(url)] ?? nil }
    }

    /// `true` if this notebook is open, or (for a folder) any notebook inside it. Moving,
    /// renaming or trashing something that is open would pull it away from its tab.
    func isOpen(at url: URL) -> Bool {
        let key = Self.key(url)
        let prefix = key.path.hasSuffix("/") ? key.path : key.path + "/"
        return openNotebooks.withLock { open in
            open.keys.contains { $0 == key || $0.path.hasPrefix(prefix) }
        }
    }

    func release(_ url: URL) {
        _ = openNotebooks.withLock { $0.removeValue(forKey: Self.key(url)) }
    }

    /// Lets go of everything a window has open (the window went away).
    func releaseAll(ownedBy window: UUID) {
        openNotebooks.withLock { open in
            open = open.filter { $0.value?.window != window }
        }
    }

    /// The same folder can be reached through different paths (symlinks, `..`).
    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
