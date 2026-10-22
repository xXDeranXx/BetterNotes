import Foundation

/// Turns a PDF that arrived from outside the app (Files picker, "Open in", drag and drop)
/// into a notebook in the library.
nonisolated enum PDFImporter {
    static let coverColor = "#4F6BED"

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// Files outside the app's sandbox are only readable after asking for temporary
    /// "security-scoped" access (the system grants it because the user picked or dropped
    /// the file). The access is given back when the copy is done. For files that are already
    /// in our own sandbox the call returns false and nothing needs to be given back.
    ///
    /// The copy itself runs off the main thread, so a big PDF never freezes the interface.
    static func importPDF(at url: URL) async throws -> NotebookPackage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let parent = LibraryLocation.documents.root
        let title = NotebookPackage.title(forImportedFile: url)
        return try await Task.detached {
            try NotebookPackage.importPDF(
                from: url, in: parent, title: title, coverColor: coverColor)
        }.value
    }
}
