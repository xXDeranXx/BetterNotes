import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

struct PageRendererTests {
    private func page(_ template: PageTemplate, size: PageSize = .a4Portrait) throws -> PDFPage {
        let data = try TemplateGenerator.makePDF(for: [PageMeta(template: template, size: size)])
        return try #require(PDFDocument(data: data)?.page(at: 0))
    }

    @Test(arguments: [0.25, 1, 2] as [CGFloat])
    func outputSizeIsPageSizeTimesScale(scale: CGFloat) throws {
        let image = PageRenderer.render(page: try page(.blank), drawing: PKDrawing(), scale: scale)

        let pixels = PixelReader(image)
        #expect(pixels.width == Int((595 * scale).rounded()))
        #expect(pixels.height == Int((842 * scale).rounded()))
    }

    @Test func landscapePagesRenderLandscape() throws {
        let image = PageRenderer.render(page: try page(.lined, size: .a4Landscape), drawing: PKDrawing(), scale: 1)

        let pixels = PixelReader(image)
        #expect(pixels.width == 842 && pixels.height == 595)
    }

    @Test func aBlankPageWithoutInkIsWhite() throws {
        let image = PageRenderer.render(page: try page(.blank), drawing: PKDrawing(), scale: 1)

        let pixels = PixelReader(image)
        for (x, y) in [(0, 0), (300, 400), (594, 841), (10, 830)] {
            #expect(pixels.isWhite(x, y))
        }
    }

    @Test func theTemplateIsDrawnWithTheRightOrientation() throws {
        // The first ruled line is 90 pt below the top of the page.
        let image = PageRenderer.render(page: try page(.lined), drawing: PKDrawing(), scale: 1)

        let pixels = PixelReader(image)
        let onLine = pixels.rgb(300, 90)
        #expect(!pixels.isWhite(300, 90) && onLine.b > onLine.r)  // light blue, so b > r
        #expect(pixels.isWhite(300, 80))  // above the first line: nothing
        #expect(pixels.isWhite(300, 842 - 90))  // the mirrored position near the bottom: nothing
    }

    @Test func inkIsDrawnWherePageCoordinatesSayItIs() throws {
        // A horizontal stroke near the TOP of the page (y = 100, y down from the top).
        let drawing = lineDrawing(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))

        let image = PageRenderer.render(page: try page(.blank), drawing: drawing, scale: 1)

        let pixels = PixelReader(image)
        #expect(pixels.isDark(200, 100))  // on the stroke
        #expect(pixels.isWhite(200, 842 - 100))  // not mirrored to the bottom
        #expect(pixels.isWhite(200, 130))  // well away from the stroke
        #expect(pixels.isWhite(50, 100))  // left of the stroke's start
    }

    @Test func inkStaysInTheSamePlaceAtADifferentScale() throws {
        let drawing = lineDrawing(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))

        let image = PageRenderer.render(page: try page(.blank), drawing: drawing, scale: 3)

        let pixels = PixelReader(image)
        #expect(pixels.isDark(600, 300))  // (200, 100) pt at 3 px per pt
        #expect(pixels.isWhite(600, 3 * (842 - 100)))
    }

    @Test func inkIsOnTopOfTheTemplate() throws {
        // A stroke exactly along the first ruled line (y = 90) must cover the blue line.
        let drawing = lineDrawing(from: CGPoint(x: 100, y: 90), to: CGPoint(x: 300, y: 90), width: 8)

        let image = PageRenderer.render(page: try page(.lined), drawing: drawing, scale: 1)

        #expect(PixelReader(image).isDark(200, 90))
    }

    @Test func inkIsBlackOnWhiteEvenInDarkMode() throws {
        let drawing = lineDrawing(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))
        let pdfPage = try page(.blank)

        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = PageRenderer.render(page: pdfPage, drawing: drawing, scale: 1)
        }

        let pixels = PixelReader(try #require(image))
        #expect(pixels.isDark(200, 100))  // not turned white by the dark appearance
        #expect(pixels.isWhite(10, 10))  // the page itself stays white
    }
}

/// Rotated pages (PDF `/Rotate`): PDFKit turns the page overlay together with the page, so
/// ink is stored in the *unrotated* page space and must be turned the same way when rendered.
struct PageRendererRotationTests {
    /// A 595 x 842 PDF page with a black square at the top-left of its unrotated content,
    /// turned by `rotation` degrees.
    private func rotatedPage(_ rotation: Int, folder: TempFolder) throws -> PDFPage {
        let source = try makeSamplePDF(in: folder.url, pageCount: 1)
        let document = try #require(PDFDocument(url: source))
        try #require(document.page(at: 0)).rotation = rotation
        let url = folder.url.appending(path: "rotated-\(rotation).pdf")
        #expect(document.write(to: url))
        return try #require(PDFDocument(url: url)?.page(at: 0))
    }

    /// Where the unrotated point (x, y) of a 595 x 842 page ends up after turning clockwise.
    private func displayed(_ x: Int, _ y: Int, rotation: Int) -> (x: Int, y: Int) {
        switch rotation {
        case 90: (842 - y, x)
        case 180: (595 - x, 842 - y)
        case 270: (y, 595 - x)
        default: (x, y)
        }
    }

    @Test(arguments: [0, 90, 180, 270])
    func theImageHasTheDisplayedSize(rotation: Int) throws {
        let folder = try TempFolder()
        let image = PageRenderer.render(
            page: try rotatedPage(rotation, folder: folder), drawing: PKDrawing(), scale: 1)

        let pixels = PixelReader(image)
        let turned = rotation % 180 != 0
        #expect(pixels.width == (turned ? 842 : 595) && pixels.height == (turned ? 595 : 842))
    }

    @Test(arguments: [0, 90, 180, 270])
    func thePDFContentIsTurnedWithThePage(rotation: Int) throws {
        let folder = try TempFolder()
        let image = PageRenderer.render(
            page: try rotatedPage(rotation, folder: folder), drawing: PKDrawing(), scale: 1)

        let pixels = PixelReader(image)
        let square = displayed(50, 50, rotation: rotation)  // the middle of the black square
        #expect(pixels.isDark(square.x, square.y))
    }

    @Test(arguments: [0, 90, 180, 270])
    func inkTurnsWithThePageAndStaysOnTheSameContent(rotation: Int) throws {
        // A stroke in unrotated page coordinates, right of the black square. After turning,
        // it must still be right of the square, wherever the square went.
        let folder = try TempFolder()
        let drawing = lineDrawing(from: CGPoint(x: 150, y: 50), to: CGPoint(x: 250, y: 50))
        let image = PageRenderer.render(
            page: try rotatedPage(rotation, folder: folder), drawing: drawing, scale: 1)

        let pixels = PixelReader(image)
        let onInk = displayed(200, 50, rotation: rotation)
        let wherePlainInkWouldBe = displayed(50, 200, rotation: rotation)  // a point the ink must not reach
        #expect(pixels.isDark(onInk.x, onInk.y))
        #expect(pixels.isWhite(wherePlainInkWouldBe.x, wherePlainInkWouldBe.y))
    }
}
