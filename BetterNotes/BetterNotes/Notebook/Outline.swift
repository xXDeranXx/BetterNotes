import Foundation
import PDFKit
import UIKit

/// One line of a notebook's outline (format version 4): a title that points at a page.
///
/// The outline is stored as a flat list, not a tree. Nesting comes from `level` (0 = top, 1 =
/// below the entry before it, ...), like headings in a document. The list is always shown in
/// page order, so moving pages around never leaves an entry in the wrong place, and an entry
/// whose page was deleted is simply not shown (undoing the delete brings it back).
nonisolated struct OutlineEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    /// The page it points at: a page id, never a page number (SPEC, "File format").
    var pageID: UUID
    var level: Int

    init(id: UUID = UUID(), title: String, pageID: UUID, level: Int = 0) {
        self.id = id
        self.title = title
        self.pageID = pageID
        self.level = max(0, level)
    }
}

/// An outline entry with the entries below it, for writing PDF bookmarks.
nonisolated struct OutlineNode: Equatable, Sendable {
    var title: String
    /// Position of the page in the list of pages the node is for.
    var pageIndex: Int
    var children: [OutlineNode] = []
}

/// Pure functions on outlines: ordering, nesting, reading and writing PDF bookmarks, and
/// guessing an outline from a PDF's text. No UI, no files; tested in `OutlineTests`.
nonisolated enum Outline {
    /// The entries to show, in page order: entries whose page is not in `pageIDs` are left out.
    /// Entries on the same page keep their stored order. Levels are made consistent, so an entry
    /// is at most one level deeper than the one shown before it.
    static func visible(_ entries: [OutlineEntry], pageIDs: [UUID]) -> [OutlineEntry] {
        let position = Dictionary(uniqueKeysWithValues: pageIDs.enumerated().map { ($1, $0) })
        let ordered = entries.enumerated()
            .compactMap { offset, entry in position[entry.pageID].map { (page: $0, offset: offset, entry: entry) } }
            .sorted { ($0.page, $0.offset) < ($1.page, $1.offset) }
            .map(\.entry)
        var result: [OutlineEntry] = []
        for var entry in ordered {
            entry.level = min(entry.level, (result.last?.level ?? -1) + 1)
            result.append(entry)
        }
        return result
    }

    /// The deepest level `entryID` may be indented to: one deeper than the entry shown before it.
    static func maximumLevel(of entryID: UUID, in visible: [OutlineEntry]) -> Int {
        guard let index = visible.firstIndex(where: { $0.id == entryID }), index > 0 else { return 0 }
        return visible[index - 1].level + 1
    }

    /// The entry that belongs to the page on screen: the last one at or before that page.
    static func current(in visible: [OutlineEntry], pageIDs: [UUID], currentPageID: UUID?) -> UUID? {
        guard let currentPageID, let current = pageIDs.firstIndex(of: currentPageID) else { return nil }
        let position = Dictionary(uniqueKeysWithValues: pageIDs.enumerated().map { ($1, $0) })
        return visible.last { (position[$0.pageID] ?? .max) <= current }?.id
    }

    /// Whether the entry at `index` of `visible` has entries below it (for the disclosure arrow).
    static func hasChildren(at index: Int, in visible: [OutlineEntry]) -> Bool {
        index + 1 < visible.count && visible[index + 1].level > visible[index].level
    }

    /// Entries hidden because an entry above them is collapsed.
    static func hiddenByCollapse(_ visible: [OutlineEntry], collapsed: Set<UUID>) -> Set<UUID> {
        var hidden: Set<UUID> = []
        var collapsedLevel: Int?  // level of the collapsed entry whose children we are inside
        for entry in visible {
            if let level = collapsedLevel {
                if entry.level > level { hidden.insert(entry.id); continue }
                collapsedLevel = nil
            }
            if collapsed.contains(entry.id) { collapsedLevel = entry.level }
        }
        return hidden
    }

    /// The nested form of the shown entries, for PDF bookmarks. `pageIDs` are the pages being
    /// written, in order (an export of some pages leaves out entries of the other pages).
    static func tree(_ entries: [OutlineEntry], pageIDs: [UUID]) -> [OutlineNode] {
        let position = Dictionary(uniqueKeysWithValues: pageIDs.enumerated().map { ($1, $0) })
        // Build with a stack of open parents, like matching nested brackets.
        var roots: [OutlineNode] = []
        var stack: [(level: Int, node: OutlineNode)] = []
        func close(downTo level: Int) {
            while let last = stack.last, last.level >= level {
                stack.removeLast()
                if stack.isEmpty { roots.append(last.node) } else { stack[stack.count - 1].node.children.append(last.node) }
            }
        }
        for entry in visible(entries, pageIDs: pageIDs) {
            close(downTo: entry.level)
            stack.append((entry.level, OutlineNode(title: entry.title, pageIndex: position[entry.pageID]!)))
        }
        close(downTo: 0)
        return roots
    }

    // MARK: PDF bookmarks

    /// The PDF's own bookmarks as entries. `pageIDs[i]` is the id of page `i` of `document`.
    /// Bookmarks without a page in this PDF are skipped (their children are kept one level up).
    static func entries(fromBookmarksOf document: PDFDocument, pageIDs: [UUID]) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineEntry] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                var childLevel = level
                let title = clean(child.label ?? "")
                if let page = child.destination?.page, case let pageIndex = document.index(for: page),
                    pageIndex >= 0, pageIndex < pageIDs.count, !title.isEmpty
                {
                    result.append(OutlineEntry(title: title, pageID: pageIDs[pageIndex], level: level))
                    childLevel = level + 1
                }
                walk(child, level: childLevel)
            }
        }
        walk(root, level: 0)
        return result
    }

    /// Writes `nodes` as the bookmarks of `document` (replacing any it had). Use a document made
    /// with `PDFDocument()` and filled with pages: one read from a file written by UIKit's PDF
    /// renderer lost its bookmarks when written (measured).
    static func writeBookmarks(_ nodes: [OutlineNode], into document: PDFDocument) {
        let root = PDFOutline()
        document.outlineRoot = root
        func add(_ nodes: [OutlineNode], to parent: PDFOutline) {
            for node in nodes {
                guard let page = document.page(at: node.pageIndex) else { continue }
                let item = PDFOutline()
                item.label = node.title
                // Top of the page, in PDF coordinates (origin bottom left).
                let box = page.bounds(for: .cropBox)
                item.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
                parent.insertChild(item, at: parent.numberOfChildren)
                add(node.children, to: item)
            }
        }
        add(nodes, to: root)
    }

    // MARK: Guessing from text

    /// An outline guessed from the text of the pages, for PDFs without bookmarks (lecture slides,
    /// exercise sheets): on each page, the text in the largest font is taken as the page's
    /// title, if it is clearly larger than the rest of the page. A title that repeats the one
    /// before it (a slide continued) is left out. Pages without text (scans) get nothing.
    ///
    /// Slow on big PDFs (it reads every page's text), so call it off the main thread with a
    /// `PDFDocument` of its own.
    static func entries(guessedFrom document: PDFDocument, pageIDs: [UUID]) -> [OutlineEntry] {
        var result: [OutlineEntry] = []
        for index in 0..<min(document.pageCount, pageIDs.count) {
            if Task.isCancelled { return [] }
            guard let text = document.page(at: index)?.attributedString,
                let title = guessTitle(text), title != result.last?.title
            else { continue }
            result.append(OutlineEntry(title: title, pageID: pageIDs[index]))
        }
        return result
    }

    /// The title of one page's text, or `nil` when no text stands out.
    static func guessTitle(_ text: NSAttributedString) -> String? {
        // How many letters there are in each font size (rounded to half points).
        var lettersBySize: [Double: Int] = [:]
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let letters = (text.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
            lettersBySize[(font.pointSize * 2).rounded() / 2, default: 0] += letters
        }
        guard let largest = lettersBySize.keys.max(),
            let body = lettersBySize.max(by: { $0.value < $1.value })?.key,
            largest >= body * 1.2  // the title must stand out from the body text
        else { return nil }

        // The first block of text in the largest size (a title can span two lines).
        var pieces: [String] = []
        var lastEnd: Int?
        text.enumerateAttribute(.font, in: whole) { value, range, stop in
            guard let font = value as? UIFont, (font.pointSize * 2).rounded() / 2 == largest else { return }
            if let lastEnd {
                // Something else in between (a line of body text): the title is over.
                let gap = (text.string as NSString).substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                if !gap.allSatisfy(\.isWhitespace) { stop.pointee = true; return }
            }
            pieces.append((text.string as NSString).substring(with: range))
            lastEnd = range.location + range.length
        }
        let title = clean(pieces.joined(separator: " "))
        // A lone number or symbol is a page number or a bullet, not a title.
        guard title.count >= 2, title.contains(where: \.isLetter) else { return nil }
        return title
    }

    /// One line, single spaces, at most 100 characters.
    static func clean(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.count > 100 ? String(oneLine.prefix(99)) + "…" : oneLine
    }
}
