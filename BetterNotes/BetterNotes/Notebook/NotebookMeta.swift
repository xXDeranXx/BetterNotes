import Foundation

/// The kind of a page. `pdf` pages come from an imported PDF; the others are drawn by
/// `TemplateGenerator` into a generated PDF.
nonisolated enum PageTemplate: String, Codable, CaseIterable, Sendable {
    case pdf, blank, lined, grid, dotted
}

/// A page size in PDF points (1/72 inch), as PDFKit reports it.
nonisolated struct PageSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    static let a4Portrait = PageSize(width: 595, height: 842)
    static let a4Landscape = PageSize(width: 842, height: 595)
}

/// One entry in `meta.json`'s `pages` list. The list has the same order as the pages
/// of `document.pdf`. Ink belongs to `id`, never to the page number.
nonisolated struct PageMeta: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var template: PageTemplate
    var size: PageSize
    /// Clockwise, in degrees: 0, 90, 180 or 270. Page operations (milestone 4) change it.
    var rotation: Int

    init(id: UUID = UUID(), template: PageTemplate, size: PageSize, rotation: Int = 0) {
        self.id = id
        self.template = template
        self.size = size
        self.rotation = rotation
    }
}

/// The contents of `meta.json`. Any change to this format increases `currentFormatVersion`
/// and comes with a migration (SPEC, "File format"). Objects (images, text boxes) are
/// added in milestone 8 together with that version bump.
nonisolated struct NotebookMeta: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Cover color as "#RRGGBB".
    var coverColor: String
    var pages: [PageMeta]

    init(
        id: UUID = UUID(), title: String, createdAt: Date, coverColor: String, pages: [PageMeta]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.coverColor = coverColor
        self.pages = pages
    }
}

nonisolated enum NotebookError: LocalizedError, Equatable {
    case unsupportedFormatVersion(Int)
    case cannotGenerateTemplate(PageTemplate)
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "This notebook was made by a newer version of the app (format \(version)). Update the app to open it."
        case .cannotGenerateTemplate(let template):
            "Pages of type \"\(template.rawValue)\" cannot be generated; they come from an imported PDF."
        case .pdfCreationFailed:
            "The page template PDF could not be created."
        }
    }
}
