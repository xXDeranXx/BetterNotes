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

    /// Set when an import failed; the window shows it in an alert and clears it.
    var importError: String?

    /// Imports PDFs as new notebooks and opens the last one that worked. Failures are
    /// collected in `importError` (one bad file does not stop the others). If a notebook is
    /// open in this window it is saved and closed first; if that fails, the new notebook is
    /// still imported and sits in the library.
    func importPDFs(_ urls: [URL]) async {
        var imported: NotebookPackage?
        var failures: [String] = []
        for url in urls {
            guard PDFImporter.isPDF(url) else {
                failures.append("\(url.lastPathComponent): this is not a PDF file.")
                continue
            }
            do {
                imported = try await PDFImporter.importPDF(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        guard let imported else { return }

        if notebook != nil { await close() }
        guard notebook == nil else {
            importError = "The PDF was imported, but the open notebook could not be saved and closed, so it was not opened. Find it in the library."
            return
        }
        do {
            try open(imported)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Saves everything, then closes. If saving fails the notebook stays open (its
    /// `saveError` explains why), because closing would throw away the unsaved ink.
    func close() async {
        guard let notebook else { return }
        await notebook.saveChanges()
        guard !notebook.hasUnsavedChanges else { return }
        self.notebook = nil
        if let claimedURL { registry.release(claimedURL) }
        claimedURL = nil
    }
}
