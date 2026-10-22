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

    func open(_ package: NotebookPackage) throws {
        notebook = try Notebook.open(package)
    }

    func close() {
        notebook = nil
    }
}
