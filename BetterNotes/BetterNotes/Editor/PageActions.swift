import Foundation

/// The page operations the interface offers (sidebar, page grid, toolbar), in one place so
/// they behave the same everywhere. Each one is a single undoable step on the notebook; a
/// failure (for example deleting the last page) is shown through `report`.
struct PageActions {
    let notebook: Notebook
    let navigator: PageNavigator
    let report: (String) -> Void

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { report(error.localizedDescription) }
    }

    /// One tap: a page like the last one at the end, and show it.
    func addPageAtEnd() {
        attempt { navigator.goTo(try notebook.addPageAtEnd()) }
    }

    /// The same with a chosen template; the size is the last page's.
    func addPageAtEnd(template: PageTemplate) {
        attempt {
            let count = notebook.pages.count
            navigator.goTo(try notebook.addPage(template: template, at: count))
        }
    }

    /// A new page next to `id`, with the chosen template.
    func insertPage(template: PageTemplate, relativeTo id: UUID, after: Bool) {
        attempt {
            guard let index = notebook.pages.firstIndex(where: { $0.id == id }) else { return }
            navigator.goTo(try notebook.addPage(template: template, at: after ? index + 1 : index))
        }
    }

    func duplicate(_ ids: Set<UUID>) { attempt { _ = try notebook.duplicatePages(ids) } }
    func rotate(_ ids: Set<UUID>, by degrees: Int) { attempt { try notebook.rotatePages(ids, by: degrees) } }
    func delete(_ ids: Set<UUID>) { attempt { try notebook.deletePages(ids) } }
}

extension PageTemplate {
    /// Name for menus; imported pages are not offered as a template.
    var menuName: String {
        switch self {
        case .blank: "Blank"
        case .lined: "Lined"
        case .grid: "Grid"
        case .dotted: "Dotted"
        case .pdf: "PDF"
        }
    }

    var menuIcon: String {
        switch self {
        case .blank: "doc"
        case .lined: "text.alignleft"
        case .grid: "squareshape.split.2x2"
        case .dotted: "circle.grid.3x3"
        case .pdf: "doc.richtext"
        }
    }

    /// The templates a user can choose for a new page.
    static let choosable: [PageTemplate] = [.blank, .lined, .grid, .dotted]
}
