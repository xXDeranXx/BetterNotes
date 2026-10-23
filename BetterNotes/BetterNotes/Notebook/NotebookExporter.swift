import Foundation
import PDFKit
import PencilKit
import UIKit

/// Turns a notebook (or some of its pages) into a flattened PDF: the original pages as they
/// are, with the ink drawn on top. The notebook itself is never changed.
///
/// Export runs through `PageRenderer.draw`, the one page renderer (SPEC, decision 4), so
/// anything that is drawn on a page, objects in milestone 8 included, shows up here too.
enum NotebookExporter {
    /// Ink is a bitmap in the exported PDF (PencilKit cannot give its strokes as vectors), drawn
    /// at this many pixels per point. 4 is 288 dpi: sharp when zoomed in on an iPad or a
    /// screen, without making the file huge.
    nonisolated static let inkScale: CGFloat = 4

    /// Writes the pages `pageIDs` (all pages when `nil`), in the order they have in the
    /// notebook, to `<temporary folder>/<title>.pdf` and returns that file. The caller moves or
    /// shares it and removes the folder afterwards (`discard`).
    ///
    /// The heavy part runs off the main thread: PencilKit and PDFKit objects are made from
    /// bytes inside the task, so nothing is shared with the editor. Throws `CancellationError`
    /// when the surrounding task is cancelled and leaves nothing behind.
    @MainActor
    static func export(
        _ notebook: Notebook, pageIDs: Set<UUID>? = nil, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard notebook.structureProblem == nil, let document = notebook.document,
            let pdfData = document.dataRepresentation()
        else { throw NotebookError.pagesCannotBeChanged }

        let indices = notebook.pages.indices.filter { pageIDs?.contains(notebook.pages[$0].id) ?? true }
        guard !indices.isEmpty else { throw NotebookError.exportHasNoPages }
        // Drawings are read here, on the main thread, because `Notebook` owns them; they are
        // plain values and go to the task as bytes.
        let drawings = indices.map { notebook.drawing(for: notebook.pages[$0].id).dataRepresentation() }
        // Reading them may have loaded drawings that no canvas needs; drop those again.
        notebook.evictOffscreenDrawings()

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = folder.appending(path: fileName(for: notebook.meta.title))
        let objects = indices.map { notebook.pages[$0].objects }
        // The outline goes along as bookmarks, for the exported pages only.
        let bookmarks = Outline.tree(notebook.outline ?? [], pageIDs: indices.map { notebook.pages[$0].id })
        let job = Job(
            pdfData: pdfData, pageIndices: indices, drawingData: drawings, objects: objects,
            images: ObjectImageSource(package: notebook.package), bookmarks: bookmarks)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A detached task does not inherit cancellation, so pass it on by hand.
            let work = Task.detached(priority: .userInitiated) {
                try write(job, to: fileURL, progress: progress)
            }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            discard(fileURL)
            throw error
        }
        return fileURL
    }

    /// Removes an exported file and the temporary folder `export` made for it.
    nonisolated static func discard(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// "<title>.pdf" with characters removed that file systems or Obsidian links dislike.
    nonisolated static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title.unicodeScalars.filter { !forbidden.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Notebook" : name) + ".pdf"
    }

    private struct Job: Sendable {
        let pdfData: Data
        let pageIndices: [Int]
        let drawingData: [Data]
        let objects: [[PageObject]]
        let images: ObjectImageSource
        let bookmarks: [OutlineNode]
    }

    private nonisolated static func write(
        _ job: Job, to url: URL, progress: (@Sendable (Double) -> Void)?
    ) throws {
        guard let source = PDFDocument(data: job.pdfData) else { throw NotebookError.pdfUnreadable }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        var failure: Error?
        try renderer.writePDF(to: url) { context in
            for (position, index) in job.pageIndices.enumerated() {
                if Task.isCancelled { failure = CancellationError(); return }
                guard let page = source.page(at: index) else { failure = NotebookError.pdfUnreadable; return }
                // Rendering is main-thread-free but not free of heat: slow down when the iPad
                // is hot (SPEC, "M2, heat safeguard": background work backs off at .serious).
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                let drawing = (try? PKDrawing(data: job.drawingData[position])) ?? PKDrawing()
                let size = PageRenderer.displayedSize(of: page)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                PageRenderer.draw(
                    page: page, drawing: drawing, objects: job.objects[position], images: job.images,
                    in: context.cgContext, contextSize: size, scale: 1, inkScale: inkScale)
                progress?(Double(position + 1) / Double(job.pageIndices.count))
            }
        }
        if let failure { throw failure }
        if !job.bookmarks.isEmpty { try addBookmarks(job.bookmarks, to: url) }
    }

    /// UIKit's PDF renderer cannot write bookmarks, so the finished pages go into a new PDFKit
    /// document that gets the outline and is written again (to a second file, then swapped in).
    /// A new document, because PDFKit dropped the bookmarks when it wrote the renderer's file
    /// itself back (measured, `OutlinePDFTests`).
    private nonisolated static func addBookmarks(_ bookmarks: [OutlineNode], to url: URL) throws {
        guard let rendered = PDFDocument(url: url) else { throw NotebookError.pdfUnreadable }
        let document = PDFDocument()
        for index in 0..<rendered.pageCount {
            guard let page = rendered.page(at: index)?.copy() as? PDFPage else { throw NotebookError.pdfUnreadable }
            document.insert(page, at: index)
        }
        Outline.writeBookmarks(bookmarks, into: document)
        let temporary = url.deletingPathExtension().appendingPathExtension("outline.pdf")
        guard document.write(to: temporary) else { throw NotebookError.pdfCreationFailed }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
