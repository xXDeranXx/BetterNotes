import Foundation
import PDFKit
import PencilKit
import UIKit

/// A page that is not (or no longer) in the notebook: its `meta.json` entry, its PDF page,
/// and optionally its ink. Page operations move these in and out of the notebook, and the
/// undo steps keep them alive, so undoing a delete brings back exactly the same page.
struct PageEntry {
    var meta: PageMeta
    var pdfPage: PDFPage
    var drawing: PKDrawing?
}

/// Page operations (SPEC, "Page management"). Every operation:
/// - changes the PDF (`document`) and the page list (`meta.pages`) together, and in the same
///   order, so they never disagree (the page list is only changed through `setPageList`);
/// - leaves ink alone, because ink belongs to a page id, not to a position;
/// - is exactly one undo step on this notebook's `UndoManager`.
///
/// Two mirror-image primitives do the work: `insertEntries` and `removeEntries`, each of
/// which registers the other as its undo. Duplicate, paste, import and "add page" are
/// inserts; delete is a remove; undoing one is the other. `applyOrder` (move) and
/// `applyRotation` register themselves in the same way.
extension Notebook {
    // MARK: Public operations

    /// Inserts ready-made pages at `index` (clamped to the page count). Ink in the entries
    /// is stored for their ids. Returns the ids of the new pages.
    @discardableResult
    func insertPages(_ entries: [PageEntry], at index: Int, actionName: String = "Insert Pages") throws -> [UUID] {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        guard !entries.isEmpty else { return [] }
        let start = min(max(index, 0), pages.count)
        performUndoableChange(actionName) {
            for entry in entries {
                if let drawing = entry.drawing { storeDrawing(drawing, for: entry.meta.id) }
            }
            let placed = entries.enumerated().map { (index: start + $0.offset, entry: $0.element) }
            insertEntries(placed)
        }
        return entries.map(\.meta.id)
    }

    /// A new empty page of the given template. The size defaults to the size of the page it
    /// goes next to (the one before `index`, or the first page when inserting at the start).
    @discardableResult
    func addPage(template: PageTemplate, at index: Int, size: PageSize? = nil) throws -> UUID {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        let start = min(max(index, 0), pages.count)
        let neighbor = pages[max(0, min(start, pages.count) - 1)]
        let entry = try Self.makeTemplatePage(template, size: size ?? neighbor.size)
        return try insertPages([entry], at: start, actionName: "Add Page")[0]
    }

    /// The one-tap "add a page at the end": same template and size as the last page; after an
    /// imported PDF page it is a blank page.
    @discardableResult
    func addPageAtEnd() throws -> UUID {
        let last = pages[pages.count - 1]
        return try addPage(template: last.template == .pdf ? .blank : last.template, at: pages.count, size: last.size)
    }

    /// Copies each page right after its original, ink included. Returns the new ids.
    @discardableResult
    func duplicatePages(_ ids: Set<UUID>) throws -> [UUID] {
        guard let document else { throw NotebookError.pagesCannotBeChanged }
        var placed: [(index: Int, entry: PageEntry)] = []
        var copies = 0
        for (index, page) in pages.enumerated() where ids.contains(page.id) {
            guard let copy = document.page(at: index)?.copy() as? PDFPage else { continue }
            let meta = page.copyWithNewIDs()  // objects come along, with new ids; image files are shared
            copies += 1
            placed.append((index: index + copies, entry: PageEntry(meta: meta, pdfPage: copy, drawing: drawing(for: page.id))))
        }
        guard !placed.isEmpty else { return [] }
        performUndoableChange("Duplicate Pages") {
            for item in placed { if let drawing = item.entry.drawing { storeDrawing(drawing, for: item.entry.meta.id) } }
            insertEntries(placed)
        }
        return placed.map(\.entry.meta.id)
    }

    /// Removes pages from the notebook. Their ink files stay on disk (SPEC, "Data safety":
    /// nothing is deleted), and undo brings the pages back. The last page cannot be deleted.
    func deletePages(_ ids: Set<UUID>) throws {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        let doomed = ids.intersection(pages.map(\.id))
        guard !doomed.isEmpty else { return }
        guard doomed.count < pages.count else { throw NotebookError.cannotDeleteAllPages }
        performUndoableChange(doomed.count == 1 ? "Delete Page" : "Delete Pages") {
            removeEntries(doomed)
        }
    }

    /// Moves pages, keeping their order among themselves, so that they land as a block at
    /// `index` of the page list **without** the moved pages (`0` = first, the number of
    /// remaining pages = last). To drop before page X, pass X's index in that reduced list.
    func movePages(_ ids: Set<UUID>, toIndex index: Int) throws {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        let moving = pages.map(\.id).filter(ids.contains)
        let staying = pages.map(\.id).filter { !ids.contains($0) }
        guard !moving.isEmpty else { return }
        let at = min(max(index, 0), staying.count)
        let order = Array(staying[..<at]) + moving + Array(staying[at...])
        guard order != pages.map(\.id) else { return }
        performUndoableChange(moving.count == 1 ? "Move Page" : "Move Pages") {
            applyOrder(order)
        }
    }

    /// Turns pages clockwise by 90, 180 or 270 degrees (or counter-clockwise with a negative
    /// value). The ink turns with the page, as PDFKit turns the page overlay.
    func rotatePages(_ ids: Set<UUID>, by degrees: Int) throws {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        let present = ids.intersection(pages.map(\.id))
        guard !present.isEmpty, degrees % 90 == 0, degrees % 360 != 0 else { return }
        performUndoableChange("Rotate Pages") {
            applyRotation(present, by: degrees)
        }
    }

    /// Gives pages made from a template (blank, lined, grid, dotted) another template. The page
    /// keeps its id, its ink, its size and its rotation; only the PDF page underneath is
    /// replaced. Imported PDF pages are left alone.
    func changeTemplate(of ids: Set<UUID>, to template: PageTemplate) throws {
        guard document != nil else { throw NotebookError.pagesCannotBeChanged }
        guard template != .pdf else { return }
        var changes: [TemplateChange] = []
        for page in pages where ids.contains(page.id) && page.template != .pdf && page.template != template {
            // `size` is the displayed size; the PDF page is made unrotated and then turned.
            let unrotated = page.rotation % 180 == 0 ? page.size : page.size.landscape
            let replacement = try Self.makeTemplatePage(template, size: unrotated).pdfPage
            replacement.rotation = page.rotation
            changes.append(TemplateChange(id: page.id, page: replacement, template: template))
        }
        guard !changes.isEmpty else { return }
        performUndoableChange("Change Template") { applyTemplateChanges(changes) }
    }

    // MARK: Making pages

    /// A page drawn from a template (blank, lined, grid, dotted) as a one-page PDF.
    static func makeTemplatePage(_ template: PageTemplate, size: PageSize) throws -> PageEntry {
        let meta = PageMeta(template: template, size: size)
        let data = try TemplateGenerator.makePDF(for: [meta])
        guard let page = PDFDocument(data: data)?.page(at: 0)?.copy() as? PDFPage else {
            throw NotebookError.pdfCreationFailed
        }
        return PageEntry(meta: meta, pdfPage: page, drawing: nil)
    }

    /// Copies of pages of another PDF, as imported-PDF pages (template `pdf`). `indexes`
    /// default to all pages. The source document is not changed.
    static func makeEntries(from source: PDFDocument, pageIndexes: [Int]? = nil) throws -> [PageEntry] {
        guard !source.isLocked else { throw NotebookError.pdfPasswordProtected }
        let indexes = pageIndexes ?? Array(0..<source.pageCount)
        guard !indexes.isEmpty else { throw NotebookError.pdfHasNoPages }
        return try indexes.map { index in
            guard let page = source.page(at: index)?.copy() as? PDFPage else { throw NotebookError.pdfUnreadable }
            return PageEntry(meta: NotebookPackage.pageMeta(of: page), pdfPage: page, drawing: nil)
        }
    }

    /// An image as a page: A4 wide, as tall as the image's proportions need, so nothing is
    /// cut off. Large photos are scaled down first to keep the PDF small.
    static func makeImagePage(from data: Data) throws -> PageEntry {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw NotebookError.imageUnreadable
        }
        let width = PageSize.a4Portrait.width
        let height = (width * image.size.height / image.size.width).rounded()
        let pageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Two screen pixels per point is plenty for a page that is read on a tablet.
        let target = CGSize(width: width * 4, height: height * 4)
        let scale = min(1, target.width / image.size.width)
        let small: UIImage
        if scale < 1 {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            small = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * scale, height: image.size.height * scale), format: format).image {
                _ in image.draw(in: CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale)))
            }
        } else {
            small = image
        }

        let pdf = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            context.beginPage()
            small.draw(in: pageRect)
        }
        guard let page = PDFDocument(data: pdf)?.page(at: 0)?.copy() as? PDFPage else {
            throw NotebookError.pdfCreationFailed
        }
        return PageEntry(
            meta: PageMeta(template: .pdf, size: PageSize(width: width, height: height)),
            pdfPage: page, drawing: nil)
    }

    /// Copies of some of this notebook's pages with new ids, ink and objects included, for
    /// putting them into another notebook (or this one). For another notebook, the image files
    /// must be copied too (see `PageTransfer`).
    func copyEntries(_ ids: Set<UUID>) throws -> [PageEntry] {
        guard let document else { throw NotebookError.pagesCannotBeChanged }
        return pages.enumerated().compactMap { index, page in
            guard ids.contains(page.id), let copy = document.page(at: index)?.copy() as? PDFPage else { return nil }
            let meta = page.copyWithNewIDs()
            return PageEntry(meta: meta, pdfPage: copy, drawing: drawing(for: page.id))
        }
    }

    // MARK: Primitives (each registers its mirror image as the undo step)

    /// Puts pages into the PDF and the page list at the given positions. Positions are
    /// indexes in the list *after* the insertion, so they are applied lowest first.
    private func insertEntries(_ items: [(index: Int, entry: PageEntry)]) {
        guard let document else { return }
        var list = pages
        for item in items.sorted(by: { $0.index < $1.index }) {
            register(item.entry.pdfPage, as: item.entry.meta.id)  // before PDFKit can ask for its overlay
            document.insert(item.entry.pdfPage, at: item.index)
            list.insert(item.entry.meta, at: item.index)
        }
        setPageList(list)
        let ids = Set(items.map(\.entry.meta.id))
        undoManager.registerUndo(withTarget: self) { notebook in
            MainActor.assumeIsolated { notebook.removeEntries(ids) }
        }
    }

    /// Takes pages out of the PDF and the page list, remembering them and their positions.
    private func removeEntries(_ ids: Set<UUID>) {
        guard let document else { return }
        var removed: [(index: Int, entry: PageEntry)] = []
        for (index, page) in pages.enumerated() where ids.contains(page.id) {
            guard let pdfPage = document.page(at: index) else { continue }
            removed.append((index: index, entry: PageEntry(meta: page, pdfPage: pdfPage, drawing: nil)))
        }
        for item in removed.reversed() { document.removePage(at: item.index) }
        setPageList(pages.filter { !ids.contains($0.id) })
        undoManager.registerUndo(withTarget: self) { notebook in
            MainActor.assumeIsolated { notebook.insertEntries(removed) }
        }
    }

    /// Rearranges the PDF and the page list into `order` (every page id exactly once).
    private func applyOrder(_ order: [UUID]) {
        guard let document else { return }
        let oldOrder = pages.map(\.id)
        var current = oldOrder
        for (target, id) in order.enumerated() {
            guard let from = current.firstIndex(of: id), from != target,
                let page = document.page(at: from)
            else { continue }
            document.removePage(at: from)
            document.insert(page, at: target)
            current.remove(at: from)
            current.insert(id, at: target)
        }
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        setPageList(order.compactMap { byID[$0] })
        undoManager.registerUndo(withTarget: self) { notebook in
            MainActor.assumeIsolated { notebook.applyOrder(oldOrder) }
        }
    }

    private struct TemplateChange {
        let id: UUID
        let page: PDFPage
        let template: PageTemplate
    }

    /// Swaps the PDF page of each listed page for another one at the same position. Undo swaps
    /// the old pages (kept alive by the undo step) back in.
    private func applyTemplateChanges(_ changes: [TemplateChange]) {
        guard let document else { return }
        var list = pages
        var previous: [TemplateChange] = []
        for change in changes {
            guard let index = list.firstIndex(where: { $0.id == change.id }),
                let old = document.page(at: index)
            else { continue }
            previous.append(TemplateChange(id: change.id, page: old, template: list[index].template))
            register(change.page, as: change.id)  // before PDFKit can ask for its overlay
            document.removePage(at: index)
            document.insert(change.page, at: index)
            list[index].template = change.template
        }
        setPageList(list)
        undoManager.registerUndo(withTarget: self) { notebook in
            MainActor.assumeIsolated { notebook.applyTemplateChanges(previous) }
        }
    }

    private func applyRotation(_ ids: Set<UUID>, by degrees: Int) {
        guard let document else { return }
        var list = pages
        for (index, page) in list.enumerated() where ids.contains(page.id) {
            guard let pdfPage = document.page(at: index) else { continue }
            pdfPage.rotation = ((pdfPage.rotation + degrees) % 360 + 360) % 360
            list[index].rotation = pdfPage.rotation
            if degrees % 180 != 0 { list[index].size = page.size.landscape }  // width and height swap
        }
        setPageList(list)
        undoManager.registerUndo(withTarget: self) { notebook in
            MainActor.assumeIsolated { notebook.applyRotation(ids, by: -degrees) }
        }
    }
}
