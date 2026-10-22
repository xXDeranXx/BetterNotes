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

    /// "Title.inkbook", or "Title 2.inkbook", "Title 3.inkbook", ... if that name is taken.
    static func uniqueURL(in parent: URL, title: String) -> URL {
        let base = fileName(forTitle: title)
        var candidate = parent.appending(path: "\(base).\(fileExtension)", directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appending(
                path: "\(base) \(number).\(fileExtension)", directoryHint: .isDirectory)
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]  // readable, stable diffs
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
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
}
