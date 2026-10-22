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

    static let a4Portrait = PaperFormat.a4.portrait
    static let a4Landscape = PaperFormat.a4.portrait.landscape

    /// The same size turned on its side.
    var landscape: PageSize { PageSize(width: height, height: width) }
}

/// Standard paper formats offered when creating a notebook (portrait size in points).
/// Any other size also works: the generator and the export only need a width and height.
nonisolated enum PaperFormat: String, CaseIterable, Identifiable, Sendable {
    case a5, a4, a3, b5, letter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a5: "A5"
        case .a4: "A4"
        case .a3: "A3"
        case .b5: "B5"
        case .letter: "US Letter"
        }
    }

    var portrait: PageSize {
        switch self {
        case .a5: PageSize(width: 420, height: 595)
        case .a4: PageSize(width: 595, height: 842)
        case .a3: PageSize(width: 842, height: 1191)
        case .b5: PageSize(width: 499, height: 709)
        case .letter: PageSize(width: 612, height: 792)
        }
    }
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
    case alreadyOpen
    case pdfUnreadable
    case pdfPasswordProtected
    case pdfHasNoPages

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "This notebook was made by a newer version of the app (format \(version)). Update the app to open it."
        case .cannotGenerateTemplate(let template):
            "Pages of type \"\(template.rawValue)\" cannot be generated; they come from an imported PDF."
        case .pdfCreationFailed:
            "The page template PDF could not be created."
        case .alreadyOpen:
            "This notebook is already open in another window. Close it there first."
        case .pdfUnreadable:
            "This file could not be read as a PDF. It may be damaged or not a PDF."
        case .pdfPasswordProtected:
            "This PDF is password protected. Remove the password in another app, then import it again."
        case .pdfHasNoPages:
            "This PDF has no pages."
        }
    }
}
