import Foundation
import Observation

/// Everything that belongs to one window (SPEC, architecture decision 5): which notebook
/// is open in it, and with that the notebook's model and undo history. Each window creates
/// its own session; nothing is shared through a global, so two windows never interfere.
///
/// Compare with React: this is like a store created per component instance with
/// `useRef`, not a module-level singleton.
@Observable
final class WindowSession {
    private(set) var notebook: Notebook?

    @ObservationIgnored private let registry: OpenNotebookRegistry
    @ObservationIgnored private var claimedURL: URL?

    init(registry: OpenNotebookRegistry = .shared) {
        self.registry = registry
    }

    /// A window that goes away without `close()` (the user swipes it away) still lets go of
    /// its notebook. Its changes were saved when the app left the foreground.
    isolated deinit {
        if let claimedURL { registry.release(claimedURL) }
    }

    func open(_ package: NotebookPackage) throws {
        guard registry.claim(package.url) else { throw NotebookError.alreadyOpen }
        do {
            notebook = try Notebook.open(package)
            claimedURL = package.url
        } catch {
            registry.release(package.url)
            throw error
        }
    }

    /// Saves everything, then closes. If saving fails the notebook stays open (its
    /// `saveError` explains why), because closing would throw away the unsaved ink.
    func close() async {
        guard let notebook else { return }
        await notebook.saveChanges()
        guard notebook.dirtyPageIDs.isEmpty else { return }
        self.notebook = nil
        if let claimedURL { registry.release(claimedURL) }
        claimedURL = nil
    }
}
