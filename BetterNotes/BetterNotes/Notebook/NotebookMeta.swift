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
    /// Images and text boxes on this page, from bottom to top (format version 2, milestone 8).
    var objects: [PageObject]

    init(id: UUID = UUID(), template: PageTemplate, size: PageSize, rotation: Int = 0, objects: [PageObject] = []) {
        self.id = id
        self.template = template
        self.size = size
        self.rotation = rotation
        self.objects = objects
    }

    private enum CodingKeys: String, CodingKey { case id, template, size, rotation, objects }

    /// Written by hand only because of `objects`: format version 1 files have no such key,
    /// and a missing key means "no objects" instead of "damaged file".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        template = try container.decode(PageTemplate.self, forKey: .template)
        size = try container.decode(PageSize.self, forKey: .size)
        rotation = try container.decode(Int.self, forKey: .rotation)
        objects = try container.decodeIfPresent([PageObject].self, forKey: .objects) ?? []
    }

    /// The same page with a new id and new object ids, for copies of a page.
    func copyWithNewIDs() -> PageMeta {
        var copy = self
        copy.id = UUID()
        copy.objects = objects.map { $0.withNewID() }
        return copy
    }
}

/// The contents of `meta.json`. Any change to this format increases `currentFormatVersion`
/// and comes with a migration (SPEC, "File format").
///
/// Version history:
/// - 1: pages with template, size and rotation.
/// - 2 (milestone 8): each page may have `objects` (images, text boxes). A version 1 file
///   reads as a version 2 file without objects; the first write keeps the old file as
///   `meta.v1.json` (see `NotebookPackage.preserveOlderFormat`).
nonisolated struct NotebookMeta: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

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
    case pagesCannotBeChanged
    case cannotDeleteAllPages
    case imageUnreadable
    case sameNotebook
    case exportHasNoPages

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
        case .pagesCannotBeChanged:
            "The pages of this notebook cannot be changed because its page list and its PDF do not match."
        case .cannotDeleteAllPages:
            "A notebook needs at least one page. Add another page first, or delete the notebook."
        case .imageUnreadable:
            "This image could not be read."
        case .sameNotebook:
            "Choose a different notebook. To copy pages inside this notebook, use Duplicate."
        case .exportHasNoPages:
            "There are no pages to export."
        }
    }
}
