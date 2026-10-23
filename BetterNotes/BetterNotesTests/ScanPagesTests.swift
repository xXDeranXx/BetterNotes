import Foundation
import PDFKit
import Testing
import UIKit
@testable import BetterNotes

@MainActor
struct ScanPagesTests {
    /// A camera-sized image full of fine noise, so JPEG cannot squeeze it down to nothing
    /// (a harder case than a real page of text).
    private func noisyScan(width: Int = 3024, height: Int = 4032) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var generator = SystemRandomNumberGenerator()
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for _ in 0..<20_000 {
                UIColor(white: CGFloat.random(in: 0...0.6, using: &generator), alpha: 1).setFill()
                context.fill(CGRect(
                    x: Int.random(in: 0..<width, using: &generator), y: Int.random(in: 0..<height, using: &generator),
                    width: Int.random(in: 2...30, using: &generator), height: Int.random(in: 2...8, using: &generator)))
            }
        }
    }

    @Test func aScanIsShrunkToAbout200DpiOnAnA4WidePage() throws {
        let jpeg = try ScanPages.jpegData(for: noisyScan())
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size.width == 1654)
        #expect(image.size.height == 2205)  // 4032 x 1654 / 3024, rounded
    }

    @Test func aSmallScanIsNotEnlarged() throws {
        let jpeg = try ScanPages.jpegData(for: noisyScan(width: 800, height: 1000))
        #expect(UIImage(data: jpeg)?.size == CGSize(width: 800, height: 1000))
    }

    @Test func thePDFEmbedsTheJPEGUnchanged() throws {
        let jpeg = try ScanPages.jpegData(for: noisyScan())
        let pdf = try ScanPages.pdfData(fromJPEGs: [jpeg])

        // If the renderer re-encoded the picture, the PDF would be much bigger than the JPEG
        // (or lose the JPEG filter). A few kilobytes of PDF structure on top are fine.
        #expect(pdf.count < jpeg.count + 20_000, "PDF \(pdf.count) bytes, JPEG \(jpeg.count) bytes")
        #expect(pdf.range(of: Data("/DCTDecode".utf8)) != nil)
    }

    @Test func theJPEGSurvivesSavingTheNotebook() throws {
        // Inserted pages, and later every page operation, are saved through PDFKit's own
        // writer (`dataRepresentation`), not our renderer; it must keep the JPEG too.
        let jpeg = try ScanPages.jpegData(for: noisyScan())
        let scan = try #require(PDFDocument(data: try ScanPages.pdfData(fromJPEGs: [jpeg])))
        let notebookPDF = PDFDocument()
        for entry in try Notebook.makeEntries(from: scan) {
            notebookPDF.insert(entry.pdfPage, at: notebookPDF.pageCount)
        }
        let saved = try #require(notebookPDF.dataRepresentation())

        #expect(saved.count < jpeg.count + 20_000, "saved \(saved.count) bytes, JPEG \(jpeg.count) bytes")
        #expect(saved.range(of: Data("/DCTDecode".utf8)) != nil)
    }

    @Test func eachScanBecomesAnA4WidePageAsTallAsItNeeds() throws {
        let tall = try ScanPages.jpegData(for: noisyScan(width: 1000, height: 1414))
        let wide = try ScanPages.jpegData(for: noisyScan(width: 1414, height: 1000))
        let document = try #require(PDFDocument(data: try ScanPages.pdfData(fromJPEGs: [tall, wide])))

        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.bounds(for: .cropBox).size == CGSize(width: 595, height: 841))
        #expect(document.page(at: 1)?.bounds(for: .cropBox).size == CGSize(width: 595, height: 421))
    }

    @Test func thePageIsNotUpsideDown() throws {
        // Top half black, bottom half white.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let document = try #require(PDFDocument(data: try ScanPages.pdfData(fromJPEGs: [try ScanPages.jpegData(for: image)])))
        let page = try #require(document.page(at: 0))
        let thumbnail = page.thumbnail(of: CGSize(width: 100, height: 100), for: .cropBox)
        let cg = try #require(thumbnail.cgImage)

        func brightness(atFraction y: CGFloat) -> CGFloat {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Core Graphics images are drawn with y up: move the wanted row to the origin.
            let row = CGFloat(cg.height) * y
            context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: row - CGFloat(cg.height), width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return CGFloat(pixel[0]) / 255
        }
        #expect(brightness(atFraction: 0.25) < 0.2)  // top: black
        #expect(brightness(atFraction: 0.75) > 0.8)  // bottom: white
    }

    @Test func notAnImageIsRefused() {
        #expect(throws: NotebookError.imageUnreadable) {
            try ScanPages.pdfData(fromJPEGs: [Data("nope".utf8)])
        }
    }

    @Test func aScanBecomesANewNotebookWithOnePagePerScan() throws {
        let folder = try TempFolder()
        let jpegs = try [noisyScan(width: 600, height: 800), noisyScan(width: 600, height: 800)].map(ScanPages.jpegData)

        let package = try NotebookPackage.importScan(
            jpegs: jpegs, in: folder.url, title: ScanPages.notebookTitle(for: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!),
            coverColor: PDFImporter.coverColor)

        let meta = try package.readMeta()
        #expect(meta.title == "Scan 15 Oct 2026")
        #expect(meta.pages.count == 2)
        #expect(meta.pages.allSatisfy { $0.template == .pdf && $0.size == PageSize(width: 595, height: 793) })
        #expect(PDFDocument(url: package.pdfURL)?.pageCount == 2)
    }
}
