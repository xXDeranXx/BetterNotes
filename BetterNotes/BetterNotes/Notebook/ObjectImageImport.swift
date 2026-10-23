import UIKit

/// Turns an image from Photos, Files or the clipboard into the file stored in a notebook's
/// `objects/` folder (decided for M8): at most `maxPixelLength` pixels on the long side, so a
/// 12-megapixel photo does not make the notebook huge. Photos become JPEG; screenshots
/// (PNG files) and images with transparency stay PNG, so text in them stays crisp.
nonisolated enum ObjectImageImport {
    static let maxPixelLength: CGFloat = 2000
    static let jpegQuality: CGFloat = 0.8

    struct Prepared: Sendable {
        let data: Data
        /// "jpg" or "png".
        let fileExtension: String
        let pixelSize: CGSize
    }

    static func prepare(_ data: Data) throws -> Prepared {
        guard let image = UIImage(data: data) else { throw NotebookError.imageUnreadable }
        return try prepare(image, original: data)
    }

    /// `original` are the image's own bytes, if known: kept unchanged when the image is small
    /// enough, upright and already in the right format, so nothing is compressed twice.
    static func prepare(_ image: UIImage, original: Data? = nil) throws -> Prepared {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { throw NotebookError.imageUnreadable }
        let sourceIsPNG = original.map(isPNG) ?? false
        let usesPNG = sourceIsPNG || hasAlpha(image)

        let factor = min(1, maxPixelLength / max(pixelSize.width, pixelSize.height))
        if factor == 1, image.imageOrientation == .up, let original,
            usesPNG ? sourceIsPNG : isJPEG(original)
        {
            return Prepared(data: original, fileExtension: usesPNG ? "png" : "jpg", pixelSize: pixelSize)
        }

        // Redrawing applies the photo's orientation (a portrait photo is stored sideways with an
        // "turn me" flag), so the stored pixels are upright and every renderer agrees.
        let size = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !usesPNG || !hasAlpha(image)
        format.preferredRange = .standard  // 8 bits per channel
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let draw: (UIGraphicsImageRendererContext) -> Void = { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let data = usesPNG ? renderer.pngData(actions: draw) : renderer.jpegData(withCompressionQuality: jpegQuality, actions: draw)
        return Prepared(data: data, fileExtension: usesPNG ? "png" : "jpg", pixelSize: size)
    }

    private static func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
    private static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        return ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
    }

    /// Where a new image goes: centered on `center`, at most 60 % of the page's width and
    /// height, never larger than the image itself on a Retina screen (2 pixels per point), and
    /// moved inside the page if it would stick out. All in page points.
    static func defaultFrame(pixelSize: CGSize, pageSize: CGSize, center: CGPoint) -> CGRect {
        let natural = CGSize(width: pixelSize.width / 2, height: pixelSize.height / 2)
        let scale = min(1, pageSize.width * 0.6 / natural.width, pageSize.height * 0.6 / natural.height)
        let size = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        let x = min(max(center.x - size.width / 2, 0), max(0, pageSize.width - size.width))
        let y = min(max(center.y - size.height / 2, 0), max(0, pageSize.height - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

extension Notebook {
    /// Stores a prepared image in the notebook and puts it on the page as one undo step
    /// ("Insert Image"). The file is written first, so `meta.json` never names a missing file.
    @discardableResult
    func insertImage(_ image: ObjectImageImport.Prepared, on pageID: UUID, center: CGPoint) throws -> PageObject {
        guard let page = pages.first(where: { $0.id == pageID }) else { throw NotebookError.pagesCannotBeChanged }
        let name = "\(UUID().uuidString).\(image.fileExtension)"
        try package.writeObjectFile(image.data, named: name)
        // `size` is the displayed size; objects live on the unrotated page.
        let unrotated = page.rotation % 180 == 0 ? page.size : page.size.landscape
        let frame = ObjectImageImport.defaultFrame(
            pixelSize: image.pixelSize, pageSize: CGSize(width: unrotated.width, height: unrotated.height), center: center)
        let object = PageObject(frame: frame, content: .image(ImageObject(file: name)))
        addObject(object, to: pageID, actionName: "Insert Image")
        return object
    }
}
