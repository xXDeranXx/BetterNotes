import CoreGraphics
import PDFKit
import Testing
import UIKit
@testable import BetterNotes

struct PageGeometryTests {
    let a4 = PageGeometry(size: CGSize(width: 595, height: 842))

    @Test func pageTopLeftIsThePDFTopLeft() {
        // Page coordinates have y down from the top; PDF coordinates have y up from the bottom.
        #expect(a4.pdfPoint(fromPage: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 842))
        #expect(a4.pdfPoint(fromPage: CGPoint(x: 595, y: 842)) == CGPoint(x: 595, y: 0))
        #expect(a4.pdfPoint(fromPage: CGPoint(x: 100, y: 200)) == CGPoint(x: 100, y: 642))
    }

    @Test func pageAndPDFPointsRoundTrip() {
        let geometry = PageGeometry(size: CGSize(width: 612, height: 792), boxOrigin: CGPoint(x: 10, y: 20))
        for point in [CGPoint.zero, CGPoint(x: 1, y: 2), CGPoint(x: 300.5, y: 700.25), CGPoint(x: 612, y: 792)] {
            #expect(geometry.pagePoint(fromPDF: geometry.pdfPoint(fromPage: point)) == point)
        }
    }

    @Test func aDisplayBoxThatDoesNotStartAtZeroShiftsPDFCoordinates() {
        let geometry = PageGeometry(size: CGSize(width: 100, height: 200), boxOrigin: CGPoint(x: 10, y: 20))

        #expect(geometry.pdfPoint(fromPage: CGPoint(x: 0, y: 0)) == CGPoint(x: 10, y: 220))
        #expect(geometry.pdfPoint(fromPage: CGPoint(x: 100, y: 200)) == CGPoint(x: 110, y: 20))
    }

    @Test func rectanglesKeepTheirSizeAndFlipTheirPosition() {
        let rect = CGRect(x: 50, y: 100, width: 200, height: 30)

        let pdf = a4.pdfRect(fromPage: rect)

        #expect(pdf == CGRect(x: 50, y: 712, width: 200, height: 30))  // 842 - (100 + 30)
        #expect(a4.pageRect(fromPDF: pdf) == rect)
    }

    @Test(arguments: [0.5, 1, 1.36, 3, 6] as [CGFloat])
    func viewAndPageCoordinatesRoundTripAtEveryZoom(zoom: CGFloat) {
        let origin = CGPoint(x: -120.5, y: 64)  // the page is scrolled partly out of the view
        for point in [CGPoint.zero, CGPoint(x: 595, y: 842), CGPoint(x: 123.4, y: 567.8)] {
            let inView = a4.viewPoint(fromPage: point, zoom: zoom, pageOrigin: origin)
            let back = a4.pagePoint(fromView: inView, zoom: zoom, pageOrigin: origin)
            #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
        }
    }

    @Test func aPointOnThePageMovesWithZoomAndScrollButItsPageCoordinatesDoNot() {
        let page = CGPoint(x: 100, y: 200)

        #expect(a4.viewPoint(fromPage: page, zoom: 1, pageOrigin: .zero) == CGPoint(x: 100, y: 200))
        #expect(a4.viewPoint(fromPage: page, zoom: 2, pageOrigin: .zero) == CGPoint(x: 200, y: 400))
        #expect(a4.viewPoint(fromPage: page, zoom: 2, pageOrigin: CGPoint(x: -50, y: 10)) == CGPoint(x: 150, y: 410))
        #expect(a4.pagePoint(fromView: CGPoint(x: 150, y: 410), zoom: 2, pageOrigin: CGPoint(x: -50, y: 10)) == page)
    }
}

/// The same conversions checked against what a real PDFView does, so a wrong assumption in
/// the formulas above would show up here.
@MainActor
struct PageGeometryAgainstPDFViewTests {
    @Test(arguments: [1.0, 2.0, 4.0] as [CGFloat])
    func geometryAgreesWithPDFViewAtSeveralZooms(zoom: CGFloat) async throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        let notebook = try Notebook.open(package)
        let coordinator = EditorCoordinator(notebook: notebook)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        let pdfView = PDFView(frame: window.bounds)
        pdfView.displayMode = .singlePageContinuous
        pdfView.pageOverlayViewProvider = coordinator
        pdfView.document = PDFDocument(url: package.pdfURL)
        window.addSubview(pdfView)
        window.makeKeyAndVisible()
        pdfView.scaleFactor = zoom
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()

        let overlay = try #require(coordinator.visibleOverlays.values.first)
        let page = try #require(pdfView.document?.page(at: 0))
        let box = page.bounds(for: pdfView.displayBox)
        let geometry = PageGeometry(size: box.size, boxOrigin: box.origin)
        let pageOriginInView = pdfView.convert(CGPoint.zero, from: overlay)

        for pagePoint in [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 200), CGPoint(x: 595, y: 842)] {
            // Page <-> PDF: ask PDFKit where the overlay's point is on the PDF page.
            let viewPoint = pdfView.convert(pagePoint, from: overlay)
            let pdfPoint = pdfView.convert(viewPoint, to: page)
            let expectedPDF = geometry.pdfPoint(fromPage: pagePoint)
            #expect(abs(pdfPoint.x - expectedPDF.x) < 0.5 && abs(pdfPoint.y - expectedPDF.y) < 0.5)

            // Page <-> view: our zoom/offset formula against PDFKit's real placement.
            let expectedView = geometry.viewPoint(
                fromPage: pagePoint, zoom: pdfView.scaleFactor, pageOrigin: pageOriginInView)
            #expect(abs(viewPoint.x - expectedView.x) < 0.5 && abs(viewPoint.y - expectedView.y) < 0.5)
        }
    }
}
