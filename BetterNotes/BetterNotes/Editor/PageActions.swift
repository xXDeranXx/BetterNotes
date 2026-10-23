import Foundation

/// The page operations the interface offers (sidebar, page grid, toolbar), in one place so
/// they behave the same everywhere. Each one is a single undoable step on the notebook; a
/// failure (for example deleting the last page) is shown through `report`.
struct PageActions {
    let notebook: Notebook
    let navigator: PageNavigator
    let report: (String) -> Void
    /// The window, so a target notebook in one of its background tabs can take the pages.
    var session: WindowSession?

    func attempt(_ work: () throws -> Void) {
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

    /// A page dragged onto another page in the grid. If the dragged page is part of the
    /// selection, the whole selection moves with it.
    func drop(_ draggedID: UUID, selection: Set<UUID>, onto target: UUID) {
        guard notebook.pages.contains(where: { $0.id == draggedID }) else {
            copyFromOtherWindow(draggedID, before: target)
            return
        }
        let moving = selection.contains(draggedID) ? selection : [draggedID]
        guard let index = PageReorder.destination(order: notebook.pages.map(\.id), moving: moving, onto: target)
        else { return }
        attempt { try notebook.movePages(moving, toIndex: index) }
    }

    /// Moves or copies pages into another notebook (see `PageTransfer`), then tells
    /// `completion` what happened so the interface can confirm it.
    func transfer(_ ids: Set<UUID>, to target: URL, move: Bool, completion: @escaping (String) -> Void) {
        let name = target.deletingPathExtension().lastPathComponent
        let count = ids.count
        Task {
            do {
                // A target in a background tab is released for the transfer and claimed again after.
                let detached = try await session?.detachTabs(under: target) ?? .none
                defer { session?.reattach(detached, movedFrom: target, to: target) }
                try await PageTransfer.transfer(ids, from: notebook, toNotebookAt: target, move: move)
                completion("\(move ? "Moved" : "Copied") \(count) \(count == 1 ? "page" : "pages") to \"\(name)\".")
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    /// A page dropped on the sidebar's empty space: one of ours moves to the end, one from
    /// another window is copied to the end.
    func dropAtEnd(_ draggedID: UUID) {
        guard notebook.pages.contains(where: { $0.id == draggedID }) else {
            copyFromOtherWindow(draggedID, before: nil)
            return
        }
        attempt { try notebook.movePages([draggedID], toIndex: notebook.pages.count - 1) }
    }

    /// A page dragged over from another window's notebook (M9): a copy goes in before `target`
    /// (at the end without one), ink, images and text included, as one undo step here. The
    /// other notebook is only read; to move the page, delete it there.
    func copyFromOtherWindow(_ pageID: UUID, before target: UUID?) {
        guard let source = WindowDirectory.notebook(containingPage: pageID), source !== notebook else {
            // Say so instead of doing nothing, so a failed drop can be told apart from one that never arrived.
            report("The dragged page was not found. Its notebook must be open in another BetterNotes window.")
            return
        }
        attempt {
            let entries = try source.copyEntries([pageID])
            // Images first: meta.json must never name a file the notebook does not have.
            try notebook.package.copyObjectFiles(
                Set(entries.flatMap(\.meta.objects).compactMap(\.imageFile)), from: source.package)
            let index = target.flatMap { id in notebook.pages.firstIndex { $0.id == id } } ?? notebook.pages.count
            let ids = try notebook.insertPages(entries, at: index, actionName: "Copy Page")
            if let first = ids.first { navigator.goTo(first) }
        }
    }

    func changeTemplate(_ ids: Set<UUID>, to template: PageTemplate) {
        attempt { try notebook.changeTemplate(of: ids, to: template) }
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
