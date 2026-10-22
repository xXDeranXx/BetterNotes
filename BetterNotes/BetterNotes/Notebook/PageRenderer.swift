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
        let box = page.bounds(for: .cropBox)  // the box PDFView displays, and the overlay's size
        let pixelSize = CGSize(
            width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
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
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                let image = drawing.image(from: CGRect(origin: .zero, size: box.size), scale: scale)
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
    }
}
