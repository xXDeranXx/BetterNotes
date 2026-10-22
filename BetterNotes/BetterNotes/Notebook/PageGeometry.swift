import CoreGraphics

/// The one place that converts between the coordinate systems of a page (SPEC, decision 6).
///
/// - **Page coordinates** (what ink and, later, objects and shapes are stored in): points on
///   the page, origin at the **top-left**, y pointing **down**. Independent of zoom and
///   scrolling. This is also what a page's overlay view and its canvas use.
/// - **PDF coordinates** (what PDFKit's `PDFPage` and annotations use): the same points,
///   origin at the **bottom-left** of the page's display box, y pointing **up**.
/// - **View coordinates**: where a point is on screen in some view showing the page at a
///   zoom, offset by where the page's top-left corner is in that view.
///
/// `size` is the size of the page's display box in points, `boxOrigin` its origin in PDF
/// coordinates (zero for generated pages; imported PDFs may differ).
nonisolated struct PageGeometry: Equatable, Sendable {
    var size: CGSize
    var boxOrigin: CGPoint = .zero

    // MARK: Page <-> PDF

    func pdfPoint(fromPage point: CGPoint) -> CGPoint {
        CGPoint(x: boxOrigin.x + point.x, y: boxOrigin.y + size.height - point.y)
    }

    func pagePoint(fromPDF point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - boxOrigin.x, y: boxOrigin.y + size.height - point.y)
    }

    func pdfRect(fromPage rect: CGRect) -> CGRect {
        CGRect(
            x: boxOrigin.x + rect.minX, y: boxOrigin.y + size.height - rect.maxY,
            width: rect.width, height: rect.height)
    }

    func pageRect(fromPDF rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - boxOrigin.x, y: boxOrigin.y + size.height - rect.maxY,
            width: rect.width, height: rect.height)
    }

    // MARK: Page <-> view

    /// `pageOrigin` is where the page's top-left corner is in the view; `zoom` is view points
    /// per page point.
    func viewPoint(fromPage point: CGPoint, zoom: CGFloat, pageOrigin: CGPoint) -> CGPoint {
        CGPoint(x: pageOrigin.x + point.x * zoom, y: pageOrigin.y + point.y * zoom)
    }

    func pagePoint(fromView point: CGPoint, zoom: CGFloat, pageOrigin: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pageOrigin.x) / zoom, y: (point.y - pageOrigin.y) / zoom)
    }
}
