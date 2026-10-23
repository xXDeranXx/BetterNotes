import PDFKit
import PencilKit
import UIKit

/// The one function that renders a page: its PDF content with the ink on top (SPEC,
/// decision 4). Thumbnails (milestone 4) and export (milestone 6) both use it, so anything
/// new on a page (objects, milestone 8) is drawn here once and shows up in both.
///
/// Objects (images, text boxes) lie below the ink (SPEC, "Objects on pages"), so they are
/// drawn between the PDF and the ink.
nonisolated enum PageRenderer {
    /// Renders `page` with its objects and `drawing` on top as an opaque image.
    /// `scale` is output pixels per page point: about 0.3 for a thumbnail, 3 or more for export.
    static func render(
        page: PDFPage, drawing: PKDrawing, objects: [PageObject] = [], images: ObjectImageSource? = nil,
        scale: CGFloat
    ) -> UIImage {
        let displayedSize = self.displayedSize(of: page)
        let pixelSize = CGSize(
            width: (displayedSize.width * scale).rounded(), height: (displayedSize.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // one image pixel per context unit: `scale` already says the resolution
        format.opaque = true

        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: pixelSize))
            draw(
                page: page, drawing: drawing, objects: objects, images: images, in: cgContext,
                contextSize: pixelSize, scale: scale, inkScale: scale)
        }
    }

    /// The page as displayed: `bounds(for:)` is the page *before* its own rotation (/Rotate).
    /// That unrotated page is what PDFKit gives the overlay and its canvas, so ink is stored in
    /// it. The result shows the page turned, so for 90 and 270 degrees width and height swap.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return normalizedRotation(of: page) % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    private static func normalizedRotation(of page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    /// Draws the page into a context whose origin is at the top-left and which is
    /// `contextSize` large, with `scale` context units per page point. An image context uses
    /// `scale` = pixels per point; a PDF context (export) uses 1, so the page stays vector.
    /// `inkScale` is the resolution of the ink, which PencilKit can only produce as a bitmap.
    /// The caller fills the background (a PDF page is white by itself, an image is filled).
    static func draw(
        page: PDFPage, drawing: PKDrawing, objects: [PageObject] = [], images: ObjectImageSource? = nil,
        in cgContext: CGContext, contextSize: CGSize, scale: CGFloat, inkScale: CGFloat
    ) {
        let box = page.bounds(for: .cropBox)
        let rotation = normalizedRotation(of: page)
        let displayedSize = self.displayedSize(of: page)

        // 1. The PDF page. The context has its origin at the top-left; PDF drawing expects
        //    the origin at the bottom-left, so flip y once here.
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: contextSize.height)
        cgContext.scaleBy(x: scale, y: -scale)
        page.draw(with: .cropBox, to: cgContext)
        cgContext.restoreGState()

        guard !objects.isEmpty || !drawing.strokes.isEmpty else { return }

        // Objects and ink are in page coordinates (top-left origin), which is already the
        // context's orientation, so no flip. They are turned with the page, exactly as PDFKit
        // turns the page's overlay on screen, so they stay on the same part of the content.
        cgContext.saveGState()
        defer { cgContext.restoreGState() }
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

        // 2. Objects, below the ink (SPEC, "Objects on pages").
        drawObjects(objects, images: images, in: cgContext)

        // 3. The ink. Pages are white, so the ink is always rendered as on white paper,
        //    whatever the system appearance.
        guard !drawing.strokes.isEmpty else { return }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let image = drawing.image(from: CGRect(origin: .zero, size: box.size), scale: inkScale)
            image.draw(in: CGRect(origin: .zero, size: box.size))
        }
    }

    // MARK: Whiteboards

    /// Renders a region of a whiteboard (page points) as an opaque image, `scale` pixels per
    /// point: the background pattern, the objects in the region, then the ink.
    static func renderBoard(
        region: CGRect, background: BoardBackground, drawing: PKDrawing, objects: [PageObject] = [],
        images: ObjectImageSource? = nil, scale: CGFloat
    ) -> UIImage {
        let pixelSize = CGSize(width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            drawBoard(
                region: region, background: background, drawing: drawing, objects: objects, images: images,
                in: context.cgContext, scale: scale, inkScale: scale)
        }
    }

    /// A small picture of everything on a whiteboard (covers, thumbnails): its content region
    /// at most `width` pixels wide, never above `maximumScale` pixels per point.
    static func renderBoardPreview(
        page: PageMeta, background: BoardBackground, drawing: PKDrawing, images: ObjectImageSource?,
        width: CGFloat, maximumScale: CGFloat
    ) -> UIImage {
        let region = Whiteboard.contentRegion(inkBounds: drawing.bounds, objects: page.objects)
        let scale = min(maximumScale, width / max(region.width, 1))
        return renderBoard(
            region: region, background: background, drawing: drawing, objects: page.objects, images: images, scale: scale)
    }

    /// Draws a region of a whiteboard into a context whose origin is the region's top-left
    /// corner, with `scale` context units per point (1 in a PDF, so the pattern and text stay
    /// vector). Only the ink inside the region becomes a bitmap, at `inkScale`; the caller keeps
    /// that within memory (`Whiteboard.inkScale`).
    static func drawBoard(
        region: CGRect, background: BoardBackground, drawing: PKDrawing, objects: [PageObject],
        images: ObjectImageSource?, in cgContext: CGContext, scale: CGFloat, inkScale: CGFloat
    ) {
        cgContext.saveGState()
        defer { cgContext.restoreGState() }
        cgContext.scaleBy(x: scale, y: scale)
        cgContext.translateBy(x: -region.minX, y: -region.minY)  // from here on, board points
        cgContext.clip(to: region)
        cgContext.setFillColor(UIColor.white.cgColor)
        cgContext.fill(region)
        Whiteboard.drawBackground(background, in: region, context: cgContext)
        drawObjects(objects.filter { $0.frame.intersects(region) }, images: images, in: cgContext)
        guard !drawing.strokes.isEmpty, !drawing.bounds.intersection(region).isEmpty else { return }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            drawing.image(from: region, scale: inkScale).draw(in: region)
        }
    }

    /// Draws objects from bottom to top into a context whose units are page points, y down.
    /// In a PDF context (export) text stays text and JPEG images are embedded as they are.
    static func drawObjects(_ objects: [PageObject], images: ObjectImageSource?, in cgContext: CGContext) {
        guard !objects.isEmpty else { return }
        // Text drawing (UIKit) draws into the "current" context; make it this one.
        UIGraphicsPushContext(cgContext)
        defer { UIGraphicsPopContext() }
        for object in objects {
            switch object.content {
            case .image(let image):
                guard let picture = images?.image(named: image.file) else {
                    // The file is missing: a grey box shows that something belongs here.
                    cgContext.setFillColor(UIColor.systemGray5.resolvedColor(with: .init(userInterfaceStyle: .light)).cgColor)
                    cgContext.fill(object.frame)
                    continue
                }
                // Core Graphics draws images with y up; flip inside the object's frame.
                cgContext.saveGState()
                cgContext.translateBy(x: object.frame.minX, y: object.frame.maxY)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.interpolationQuality = .high
                cgContext.draw(picture, in: CGRect(origin: .zero, size: object.frame.size))
                cgContext.restoreGState()
            case .text(let text):
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    TextBoxLayout.draw(text, in: object.frame)
                }
            }
        }
    }
}

/// Reads object images from a notebook's `objects/` folder for drawing. Safe to use off the
/// main thread (export draws in the background).
nonisolated struct ObjectImageSource: Sendable {
    let folder: URL

    init(folder: URL) { self.folder = folder }
    init(package: NotebookPackage) { self.folder = package.objectsURL }

    /// The image as Core Graphics knows it. JPEG and PNG files are opened with their own
    /// decoders on purpose: a PDF export then embeds the JPEG bytes unchanged instead of a
    /// much bigger decoded bitmap (as for scans, see `ScanPages.pdfData`).
    func image(named name: String) -> CGImage? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)),
            let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg":
            return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case "png":
            return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        default:
            return UIImage(data: data)?.cgImage
        }
    }
}
