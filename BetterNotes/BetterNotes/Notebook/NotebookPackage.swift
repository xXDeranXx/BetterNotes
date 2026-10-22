import Foundation
import PencilKit

/// A `.inkbook` folder on disk (see SPEC, "File format"). Pure file access: no UI, no
/// model. Every write is atomic: Foundation writes a temporary file next to the target
/// and swaps it in, so a crash leaves the old file or the new one, never half of one.
nonisolated struct NotebookPackage: Sendable {
    static let fileExtension = "inkbook"

    let url: URL

    var pdfURL: URL { url.appending(path: "document.pdf") }
    var metaURL: URL { url.appending(path: "meta.json") }
    var drawingsURL: URL { url.appending(path: "drawings", directoryHint: .isDirectory) }

    func drawingURL(for pageID: UUID) -> URL {
        drawingsURL.appending(path: "\(pageID.uuidString).drawing")
    }

    // MARK: Create

    /// Creates a new one-page notebook in `parent`. The package is built in a hidden
    /// temporary folder and renamed into place at the end, so an interrupted create never
    /// leaves a half-made notebook that looks real.
    static func create(
        in parent: URL, title: String, template: PageTemplate, size: PageSize,
        coverColor: String, now: Date = .now
    ) throws -> NotebookPackage {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let page = PageMeta(template: template, size: size)
        let meta = NotebookMeta(title: title, createdAt: now, coverColor: coverColor, pages: [page])
        let pdf = try TemplateGenerator.makePDF(for: meta.pages)

        let staging = parent.appending(path: ".\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            let stagingPackage = NotebookPackage(url: staging)
            for folder in ["drawings", "objects", "thumbnails"] {
                try fileManager.createDirectory(
                    at: staging.appending(path: folder), withIntermediateDirectories: true)
            }
            try pdf.write(to: stagingPackage.pdfURL, options: .atomic)
            try stagingPackage.writeMeta(meta)

            // moveItem fails if the target exists, so a name clash can never overwrite a notebook.
            let final = uniqueURL(in: parent, title: title)
            try fileManager.moveItem(at: staging, to: final)
            return NotebookPackage(url: final)
        } catch {
            try? fileManager.removeItem(at: staging)  // only our own temporary folder
            throw error
        }
    }

    /// "Title.inkbook", or "Title (2).inkbook", "Title (3).inkbook", ... if that name is taken.
    static func uniqueURL(in parent: URL, title: String) -> URL {
        let base = fileName(forTitle: title)
        var candidate = parent.appending(path: "\(base).\(fileExtension)", directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appending(
                path: "\(base) (\(number)).\(fileExtension)", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }

    static func fileName(forTitle title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "." })  // a leading dot would hide the notebook
        return cleaned.isEmpty ? "Untitled" : String(cleaned)
    }

    // MARK: meta.json

    func readMeta() throws -> NotebookMeta {
        let data = try Data(contentsOf: metaURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Read the version first: a newer format may have fields we cannot decode, and
        // "made by a newer app" is a better message than "data is corrupt".
        struct VersionProbe: Decodable { var formatVersion: Int }
        let version = try decoder.decode(VersionProbe.self, from: data).formatVersion
        guard version <= NotebookMeta.currentFormatVersion else {
            throw NotebookError.unsupportedFormatVersion(version)
        }
        return try decoder.decode(NotebookMeta.self, from: data)
    }

    func writeMeta(_ meta: NotebookMeta) throws {
        try Self.encode(meta).write(to: metaURL, options: .atomic)
    }

    private static func encode(_ meta: NotebookMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]  // readable, stable diffs
        return try encoder.encode(meta)
    }

    // MARK: Changing the pages (document.pdf and meta.json together)

    private var pendingURL: URL { url.appending(path: "pending", directoryHint: .isDirectory) }
    private var commitMarkerURL: URL { pendingURL.appending(path: "COMMIT") }
    private static let structureFiles = ["document.pdf", "meta.json"]

    /// Replaces `document.pdf` and `meta.json` as one unit. They are two files, and the page
    /// list must always match the PDF (SPEC, "File format"), so a crash between writing the
    /// two must not leave a pair that disagrees:
    /// 1. both new files are written into `pending/`, each atomically;
    /// 2. an empty `COMMIT` file is written last, which means "the new pair is complete";
    /// 3. the files are moved over the old ones.
    /// If the app dies before step 2, `pending/` is incomplete and is thrown away on the next
    /// open (the old pair is untouched). If it dies during step 3, the next open finishes the
    /// move (`finishPendingCommit`). Either way the notebook opens with a matching pair.
    func commitStructure(pdfData: Data, meta: NotebookMeta) throws {
        try stageStructure(pdfData: pdfData, meta: meta)
        try finishPendingCommit()
    }

    /// Steps 1 and 2 of `commitStructure`; separate so tests can stop "in the middle".
    func stageStructure(pdfData: Data, meta: NotebookMeta) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: pendingURL.path) { try fileManager.removeItem(at: pendingURL) }
        try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        try pdfData.write(to: pendingURL.appending(path: "document.pdf"), options: .atomic)
        try Self.encode(meta).write(to: pendingURL.appending(path: "meta.json"), options: .atomic)
        try Data().write(to: commitMarkerURL, options: .atomic)
    }

    /// Step 3, and the repair after a crash: finishes a complete `pending/` or discards an
    /// incomplete one. Does nothing when there is no `pending/`. Safe to call any time.
    func finishPendingCommit() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        if fileManager.fileExists(atPath: commitMarkerURL.path) {
            for name in Self.structureFiles {
                let staged = pendingURL.appending(path: name)
                // A file that is already gone was moved before an interruption.
                if fileManager.fileExists(atPath: staged.path) {
                    _ = try fileManager.replaceItemAt(url.appending(path: name), withItemAt: staged)
                }
            }
        }
        try fileManager.removeItem(at: pendingURL)  // our own staging folder, never user data
    }

    // MARK: Drawings

    func saveDrawing(_ drawing: PKDrawing, for pageID: UUID) throws {
        try drawing.dataRepresentation().write(to: drawingURL(for: pageID), options: .atomic)
    }

    /// `nil` means the page has no saved ink yet.
    func loadDrawing(for pageID: UUID) throws -> PKDrawing? {
        let url = drawingURL(for: pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PKDrawing(data: Data(contentsOf: url))
    }

    /// Copies a drawing file that could not be read to `<id>.drawing.unreadable` (or
    /// `-2`, `-3`, ... if that exists), so overwriting the page's ink never destroys the only
    /// copy of data that might still be recoverable by hand. Does nothing if there is no file.
    func preserveUnreadableDrawing(for pageID: UUID) throws {
        let fileManager = FileManager.default
        let source = drawingURL(for: pageID)
        guard fileManager.fileExists(atPath: source.path) else { return }
        var copy = drawingsURL.appending(path: "\(pageID.uuidString).drawing.unreadable")
        var number = 2
        while fileManager.fileExists(atPath: copy.path) {
            copy = drawingsURL.appending(path: "\(pageID.uuidString).drawing.unreadable-\(number)")
            number += 1
        }
        try fileManager.copyItem(at: source, to: copy)
    }
}
