import PDFKit
import PencilKit
import UIKit

/// The one function that renders a page: its PDF content with the ink on top (SPEC,
/// decision 4). Thumbnails (milestone 4) and export (milestone 6) both use it, so anything
/// new on a page (objects, milestone 8) is drawn here once and shows up in both.
///
/// Objects lie below the ink (SPEC, "Objects on pages"), so when they exist they are drawn
/// between the PDF and the ink.
nonisolated enum PageRenderer {
    /// Renders `page` with `drawing` on top as an opaque image.
    /// `scale` is output pixels per page point: about 0.3 for a thumbnail, 3 or more for export.
    static func render(page: PDFPage, drawing: PKDrawing, scale: CGFloat) -> UIImage {
        // `bounds(for:)` is the page *before* its own rotation (/Rotate). That unrotated page is
        // what PDFKit gives the overlay and its canvas, so ink is stored in it. The image shows
        // the page as displayed, i.e. turned, so for 90 and 270 degrees width and height swap.
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let displayedSize = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let pixelSize = CGSize(
            width: (displayedSize.width * scale).rounded(), height: (displayedSize.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // one image pixel per context unit: `scale` already says the resolution
        format.opaque = true

        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: pixelSize))

            // 1. The PDF page. The context has its origin at the top-left; PDF drawing expects
            //    the origin at the bottom-left, so flip y once here.
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pixelSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: cgContext)
            cgContext.restoreGState()

            // 2. Objects (milestone 8) go here, below the ink.

            // 3. The ink. Its coordinates are page coordinates (top-left origin), which is
            //    already the context's orientation, so no flip. Pages are white, so the ink
            //    is always rendered as on white paper, whatever the system appearance.
            //    The ink is turned with the page, exactly as PDFKit turns the page's overlay
            //    on screen, so it stays on the same part of the content.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                let image = drawing.image(from: CGRect(origin: .zero, size: box.size), scale: scale)
                cgContext.saveGState()
                cgContext.scaleBy(x: scale, y: scale)  // from here on, units are page points
                switch rotation {
                case 90:
                    cgContext.translateBy(x: displayedSize.width, y: 0)
                    cgContext.rotate(by: .pi / 2)
                case 180:
                    cgContext.translateBy(x: displayedSize.width, y: displayedSize.height)
                    cgContext.rotate(by: .pi)
                case 270:
                    cgContext.translateBy(x: 0, y: displayedSize.height)
                    cgContext.rotate(by: -.pi / 2)
                default:
                    break
                }
                image.draw(in: CGRect(origin: .zero, size: box.size))
                cgContext.restoreGState()
            }
        }
    }
}
