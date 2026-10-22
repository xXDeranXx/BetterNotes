import Observation
import PDFKit
import UIKit

/// Text search inside the open notebook's PDF (SPEC, "Notebooks and PDFs"). It finds text
/// that is part of the PDF (lecture slides, exercise sheets); handwriting is not searched.
///
/// The search bar in SwiftUI reads `query`, `matches` and `currentIndex` from here, and the
/// editor attaches its `PDFView` so highlights and scrolling happen on the real view.
/// Compare with React: this is the state object of the search box, kept outside the component.
@Observable
final class DocumentSearch {
    var query = ""
    private(set) var matches: [PDFSelection] = []
    /// Index into `matches` of the match that is shown as current.
    private(set) var currentIndex = 0
    /// True once a search ran for the current text, so "no matches" is not shown before any search.
    private(set) var hasSearched = false

    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var lastSearchedText = ""

    static let matchColor = UIColor.systemYellow.withAlphaComponent(0.5)
    static let currentColor = UIColor.systemOrange.withAlphaComponent(0.7)

    /// Return pressed in the search field: search for new text, or go to the next match if
    /// the text did not change since the last search.
    func submit() {
        if hasSearched, trimmedQuery == lastSearchedText {
            next()
        } else {
            run()
        }
    }

    func run() {
        let text = trimmedQuery
        guard !text.isEmpty, let document = pdfView?.document else {
            clear()
            return
        }
        matches = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
        lastSearchedText = text
        hasSearched = true
        currentIndex = 0
        show()
    }

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    /// Removes the highlights and forgets the results (the text in the field stays).
    func clear() {
        matches = []
        currentIndex = 0
        hasSearched = false
        lastSearchedText = ""
        pdfView?.highlightedSelections = nil
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Wraps around at both ends.
    private func move(by step: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + step + matches.count) % matches.count
        show()
    }

    /// Highlights all matches (the current one in a stronger color) and scrolls to the current one.
    private func show() {
        for (index, match) in matches.enumerated() {
            match.color = index == currentIndex ? Self.currentColor : Self.matchColor
        }
        pdfView?.highlightedSelections = matches
        if matches.indices.contains(currentIndex) {
            pdfView?.go(to: matches[currentIndex])
        }
    }
}
