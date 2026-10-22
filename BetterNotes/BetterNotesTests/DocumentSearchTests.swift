import PDFKit
import Testing
import UIKit
@testable import BetterNotes

@MainActor
@Suite struct DocumentSearchTests {
    /// A PDF with one line of real text per page.
    private func makeSearch(pageTexts: [String]) throws -> (DocumentSearch, PDFView, TempFolder) {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "text.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { context in
            for text in pageTexts {
                context.beginPage()
                (text as NSString).draw(
                    at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        pdfView.document = PDFDocument(url: url)
        let search = DocumentSearch()
        search.pdfView = pdfView
        return (search, pdfView, temp)
    }

    @Test func findsMatchesOnAllPagesIgnoringCase() throws {
        let (search, _, _) = try makeSearch(pageTexts: ["Gradient descent", "no hit here", "the GRADIENT again"])

        search.query = "gradient"
        search.run()

        #expect(search.matches.count == 2)
        #expect(search.hasSearched)
        #expect(search.currentIndex == 0)
    }

    @Test func nextAndPreviousWrapAround() throws {
        let (search, _, _) = try makeSearch(pageTexts: ["cat", "cat", "cat"])
        search.query = "cat"
        search.run()

        search.next(); search.next()
        #expect(search.currentIndex == 2)
        search.next()
        #expect(search.currentIndex == 0)  // wrapped forward
        search.previous()
        #expect(search.currentIndex == 2)  // wrapped backward
    }

    @Test func highlightsAllMatchesAndMarksTheCurrentOne() throws {
        let (search, pdfView, _) = try makeSearch(pageTexts: ["cat", "cat"])
        search.query = "cat"
        search.run()

        #expect(pdfView.highlightedSelections?.count == 2)
        #expect(search.matches[0].color == DocumentSearch.currentColor)
        #expect(search.matches[1].color == DocumentSearch.matchColor)

        search.next()
        #expect(search.matches[0].color == DocumentSearch.matchColor)
        #expect(search.matches[1].color == DocumentSearch.currentColor)
    }

    @Test func noMatchesIsReportedAndClearsOldHighlights() throws {
        let (search, pdfView, _) = try makeSearch(pageTexts: ["cat"])
        search.query = "cat"
        search.run()
        #expect(search.matches.count == 1)

        search.query = "dog"
        search.run()

        #expect(search.matches.isEmpty)
        #expect(search.hasSearched)  // so the bar can say "No matches"
        #expect(pdfView.highlightedSelections?.isEmpty ?? true)
    }

    @Test func clearRemovesHighlightsAndResults() throws {
        let (search, pdfView, _) = try makeSearch(pageTexts: ["cat"])
        search.query = "cat"
        search.run()

        search.clear()

        #expect(search.matches.isEmpty)
        #expect(!search.hasSearched)
        #expect(pdfView.highlightedSelections == nil)
    }

    @Test func emptyQueryFindsNothing() throws {
        let (search, _, _) = try makeSearch(pageTexts: ["cat"])
        search.query = "   "
        search.run()

        #expect(search.matches.isEmpty)
        #expect(!search.hasSearched)
    }

    @Test func submitSearchesFirstThenGoesToTheNextMatch() throws {
        let (search, _, _) = try makeSearch(pageTexts: ["cat", "cat"])
        search.query = "cat"

        search.submit()
        #expect(search.matches.count == 2)
        #expect(search.currentIndex == 0)

        search.submit()  // same text: Return means "next"
        #expect(search.currentIndex == 1)

        search.query = "dog"
        search.submit()  // new text: Return means "search again"
        #expect(search.matches.isEmpty)
    }
}
