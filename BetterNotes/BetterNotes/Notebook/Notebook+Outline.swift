import Foundation
import PDFKit

/// Outline operations (M9). Each one is a single undo step through `setOutline`. Entries are
/// kept in the stored list even when their page is gone (see `OutlineEntry`), so they come
/// back when a page delete is undone.
extension Notebook {
    /// The entries to show, in page order (see `Outline.visible`).
    var visibleOutline: [OutlineEntry] {
        Outline.visible(outline ?? [], pageIDs: pages.map(\.id))
    }

    /// Fills the outline the first time it is needed: from the PDF's own bookmarks, or else
    /// guessed from the text of its pages. A notebook made only from templates starts empty.
    /// The PDF is read off the main thread from its bytes, so a 300-page PDF does not stall
    /// the pen. Does nothing when the outline was set up before.
    func setUpOutlineIfNeeded() async {
        guard outline == nil else { return }
        guard pages.contains(where: { $0.template == .pdf }), let data = document?.dataRepresentation() else {
            setUpOutline([])
            return
        }
        let pageIDs = pages.map(\.id)
        let entries = await Task.detached(priority: .utility) { Self.readOutline(pdfData: data, pageIDs: pageIDs) }.value
        // Pages may have changed meanwhile: keep only entries whose page still exists.
        let present = Set(pages.map(\.id))
        setUpOutline(entries.filter { present.contains($0.pageID) })
    }

    /// Adds an entry for a page, after the entries already on that page. Its level is the one
    /// of the entry shown before it, so adding below a sub-entry adds a sibling.
    @discardableResult
    func addOutlineEntry(title: String, pageID: UUID) -> UUID? {
        let title = Outline.clean(title)
        guard !title.isEmpty, pages.contains(where: { $0.id == pageID }) else { return nil }
        let pageIDs = pages.map(\.id)
        guard let pageIndex = pageIDs.firstIndex(of: pageID) else { return nil }
        let before = visibleOutline.last { (pageIDs.firstIndex(of: $0.pageID) ?? .max) <= pageIndex }
        let entry = OutlineEntry(title: title, pageID: pageID, level: before?.level ?? 0)
        setOutline((outline ?? []) + [entry], actionName: "Add to Outline")
        return entry.id
    }

    func renameOutlineEntry(_ id: UUID, to title: String) {
        let title = Outline.clean(title)
        guard !title.isEmpty else { return }
        changeOutlineEntry(id, actionName: "Rename") { $0.title = title }
    }

    /// One level deeper (at most one deeper than the entry above it), or one level up.
    func indentOutlineEntry(_ id: UUID, by step: Int) {
        let maximum = Outline.maximumLevel(of: id, in: visibleOutline)
        let current = visibleOutline.first { $0.id == id }?.level ?? 0
        let level = min(max(0, current + step), maximum)
        changeOutlineEntry(id, actionName: step > 0 ? "Indent" : "Outdent") { $0.level = level }
    }

    /// Removes one entry; the entries below it move up under the entry before it.
    func deleteOutlineEntry(_ id: UUID) {
        guard let outline else { return }
        setOutline(outline.filter { $0.id != id }, actionName: "Delete from Outline")
    }

    /// Replaces the outline with one guessed from the pages' text (the menu's "Generate from
    /// Text"). Undoable. Returns how many entries were found; with none, nothing changes.
    @discardableResult
    func regenerateOutlineFromText() async -> Int {
        guard let data = document?.dataRepresentation() else { return 0 }
        let pageIDs = pages.map(\.id)
        let entries = await Task.detached(priority: .userInitiated) { Self.readOutline(pdfData: data, pageIDs: pageIDs) }.value
        let present = Set(pages.map(\.id))
        let found = entries.filter { present.contains($0.pageID) }
        // Nothing found (a scan): keep what is there instead of wiping it.
        if !found.isEmpty { setOutline(found, actionName: "Generate Outline") }
        return found.count
    }

    func clearOutline() {
        setOutline([], actionName: "Clear Outline")
    }

    /// The PDF's bookmarks, or else an outline guessed from its text. Runs off the main thread.
    nonisolated private static func readOutline(pdfData: Data, pageIDs: [UUID]) -> [OutlineEntry] {
        guard let copy = PDFDocument(data: pdfData) else { return [] }
        let bookmarks = Outline.entries(fromBookmarksOf: copy, pageIDs: pageIDs)
        return bookmarks.isEmpty ? Outline.entries(guessedFrom: copy, pageIDs: pageIDs) : bookmarks
    }

    private func changeOutlineEntry(_ id: UUID, actionName: String, _ change: (inout OutlineEntry) -> Void) {
        guard var list = outline, let index = list.firstIndex(where: { $0.id == id }) else { return }
        // Store the level the entry is shown with, so a change starts from what the user sees.
        if let shown = visibleOutline.first(where: { $0.id == id }) { list[index].level = shown.level }
        change(&list[index])
        setOutline(list, actionName: actionName)
    }
}
