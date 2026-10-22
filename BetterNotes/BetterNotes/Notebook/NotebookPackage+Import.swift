import Foundation
import PDFKit

nonisolated extension NotebookPackage {
    /// Makes a new notebook from a PDF (SPEC, "Core idea"): the PDF is **copied** to
    /// `document.pdf` and used as it is; the original file is never touched. Pages get
    /// template `pdf`, and their size is the size PDFView displays (the crop box, turned by
    /// the page's own rotation), so `meta.json` agrees with what the editor shows.
    ///
    /// Like `create`, the package is built in a hidden staging folder and renamed into place
    /// at the end, so an interrupted import never leaves a half-made notebook.
    ///
    /// For a file picked in the Files app the caller must already have security-scoped
    /// access to `pdfURL`; this function only reads it.
    static func importPDF(
        from pdfURL: URL, in parent: URL, title: String, coverColor: String, now: Date = .now
    ) throws -> NotebookPackage {
        let pages = try readPages(of: pdfURL)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            let stagingPackage = NotebookPackage(url: staging)
            for folder in ["drawings", "objects", "thumbnails"] {
                try fileManager.createDirectory(
                    at: staging.appending(path: folder), withIntermediateDirectories: true)
            }
            try fileManager.copyItem(at: pdfURL, to: stagingPackage.pdfURL)
            try stagingPackage.writeMeta(
                NotebookMeta(title: title, createdAt: now, coverColor: coverColor, pages: pages))

            let final = uniqueURL(in: parent, title: title)
            try fileManager.moveItem(at: staging, to: final)
            return NotebookPackage(url: final)
        } catch {
            try? fileManager.removeItem(at: staging)  // only our own temporary folder
            throw error
        }
    }

    /// One `PageMeta` per page of the PDF, in the PDF's order. Throws if the file is not a
    /// usable PDF.
    static func readPages(of pdfURL: URL) throws -> [PageMeta] {
        guard let document = PDFDocument(url: pdfURL) else { throw NotebookError.pdfUnreadable }
        // A password-protected PDF opens as a document but has no readable pages.
        guard !document.isLocked else { throw NotebookError.pdfPasswordProtected }
        guard document.pageCount > 0 else { throw NotebookError.pdfHasNoPages }

        // A page that cannot be read is an error, not a gap: `pages` must have exactly as
        // many entries as the PDF (SPEC, "File format").
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw NotebookError.pdfUnreadable }
            return pageMeta(of: page)
        }
    }

    /// The `meta.json` entry for a page of an imported PDF.
    static func pageMeta(of page: PDFPage) -> PageMeta {
        // `bounds(for:)` ignores the page's own rotation (measured: a page rotated by 90
        // still reports the unrotated box), but PDFView shows it turned. So swap here.
        let box = page.bounds(for: .cropBox)
        let size = PageSize(width: box.width, height: box.height)
        let turnedOnItsSide = page.rotation % 180 != 0
        return PageMeta(
            template: .pdf, size: turnedOnItsSide ? size.landscape : size, rotation: page.rotation)
    }

    /// The notebook title for an imported file: its name without ".pdf".
    static func title(forImportedFile url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
