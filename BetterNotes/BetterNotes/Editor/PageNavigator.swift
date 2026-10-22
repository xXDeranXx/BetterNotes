import Observation
import PDFKit

/// Lets SwiftUI know which page is on screen and lets it scroll the editor to a page. The
/// editor attaches its `PDFView` (like `DocumentSearch` does); the sidebar and the grid use this.
@Observable
final class PageNavigator {
    /// The page the editor currently shows (the one PDFView considers current).
    private(set) var currentPageID: UUID?

    @ObservationIgnored private let notebook: Notebook
    @ObservationIgnored private weak var pdfView: PDFView?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(notebook: Notebook) {
        self.notebook = notebook
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(_ pdfView: PDFView) {
        self.pdfView = pdfView
        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func goTo(_ id: UUID) {
        guard let index = notebook.pages.firstIndex(where: { $0.id == id }),
            let page = notebook.document?.page(at: index)
        else { return }
        pdfView?.go(to: page)
        refresh()
    }

    private func refresh() {
        currentPageID = pdfView?.currentPage.flatMap { notebook.pageID(for: $0) }
    }
}
