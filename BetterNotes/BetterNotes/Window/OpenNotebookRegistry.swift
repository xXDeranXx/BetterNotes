import Foundation
import Synchronization

/// Remembers which notebooks are open in some window of this app (SPEC, "Data safety": a
/// notebook is open in at most one window). Two windows editing the same notebook would each
/// hold their own model and overwrite each other's drawing files.
///
/// This is the one piece of shared state between windows, because it is exactly the
/// coordination between them. Window state (the notebook, its model, its undo history) stays
/// in each window's `WindowSession`. Bringing the existing window to the front arrives in
/// milestone 9; until then the second open is refused with a message.
nonisolated final class OpenNotebookRegistry: Sendable {
    static let shared = OpenNotebookRegistry()

    private let openNotebooks = Mutex<Set<URL>>([])

    /// `true` if the notebook was free and is now claimed; `false` if a window has it open.
    func claim(_ url: URL) -> Bool {
        openNotebooks.withLock { $0.insert(Self.key(url)).inserted }
    }

    func release(_ url: URL) {
        _ = openNotebooks.withLock { $0.remove(Self.key(url)) }
    }

    /// The same folder can be reached through different paths (symlinks, `..`).
    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
