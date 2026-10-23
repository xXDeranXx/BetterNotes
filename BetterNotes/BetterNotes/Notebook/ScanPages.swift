import Foundation
import UIKit

/// Turns camera scans into small PDF pages (SPEC, "Scan documents"). A scan is a photo of
/// about 12 megapixels, and every page operation rewrites the whole `document.pdf`, so each
/// page is made small on purpose: shrunk to about 200 dpi on an A4-wide page, then stored
/// as a JPEG that the PDF embeds as it is.
nonisolated enum ScanPages {
    /// 1654 pixels across an A4-wide page (8.27 inches) is about 200 dpi.
    static let maxPixelWidth: CGFloat = 1654
    static let jpegQuality: CGFloat = 0.7

    /// A scanned page as a small JPEG: at most `maxPixelWidth` pixels wide (never enlarged).
    static func jpegData(for image: UIImage) throws -> Data {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { throw NotebookError.imageUnreadable }

        let factor = min(1, maxPixelWidth / pixelWidth)
        let size = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1             // pixels, not points
        format.opaque = true         // no alpha channel: a page is never see-through
        format.preferredRange = .standard  // 8 bits per channel, not wide color
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = small.jpegData(compressionQuality: jpegQuality) else { throw NotebookError.imageUnreadable }
        return data
    }

    /// A PDF with one page per JPEG: A4 wide and as tall as the scan's shape needs, so
    /// nothing is cut off or stretched (the same rule as "image as a page").
    ///
    /// The image is made with `CGImage(jpegDataProviderSource:)` on purpose: Core Graphics
    /// then knows the pixels are JPEG data and copies them into the PDF unchanged. Drawing
    /// a decoded image instead lets the PDF renderer store it in a much bigger format.
    static func pdfData(fromJPEGs jpegs: [Data]) throws -> Data {
        guard !jpegs.isEmpty else { throw NotebookError.pdfHasNoPages }
        let images = try jpegs.map { data -> CGImage in
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  image.width > 0, image.height > 0
            else { throw NotebookError.imageUnreadable }
            return image
        }

        let width = PageSize.a4Portrait.width
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: width)).pdfData { context in
            for image in images {
                let height = (width * CGFloat(image.height) / CGFloat(image.width)).rounded()
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.beginPage(withBounds: rect, pageInfo: [:])
                // UIKit's drawing context has y pointing down, Core Graphics draws images
                // with y up, so flip before drawing or the page comes out upside down.
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: height)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(image, in: rect)
                cg.restoreGState()
            }
        }
    }

    /// The title of a notebook made from a scan, for example "Scan 23 Oct 2026".
    static func notebookTitle(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")  // the app is English only
        formatter.dateFormat = "d MMM yyyy"
        return "Scan \(formatter.string(from: date))"
    }
}

nonisolated extension NotebookPackage {
    /// Makes a new notebook from scanned pages (JPEGs from `ScanPages.jpegData`). The PDF
    /// is written to a temporary file and imported like any PDF, so it gets the same
    /// staging folder and page sizes as an import.
    static func importScan(
        jpegs: [Data], in parent: URL, title: String, coverColor: String
    ) throws -> NotebookPackage {
        let pdf = try ScanPages.pdfData(fromJPEGs: jpegs)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try pdf.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }  // our own temporary file
        return try importPDF(from: temporary, in: parent, title: title, coverColor: coverColor)
    }
}
