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
