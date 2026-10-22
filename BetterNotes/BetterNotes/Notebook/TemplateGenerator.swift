import CoreGraphics
import Foundation

/// Draws blank, lined, grid and dotted pages as vector graphics into a PDF, so exports
/// show them (SPEC, "Notebooks and PDFs").
///
/// CoreGraphics (not UIKit) is used on purpose: it has the same coordinate system as
/// PDFKit (origin bottom-left, y up) and can run off the main thread.
nonisolated enum TemplateGenerator {
    private static let lineSpacing = 28.0
    private static let gridSpacing = 20.0

    static func makePDF(for pages: [PageMeta]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw NotebookError.pdfCreationFailed }

        for page in pages {
            guard page.template != .pdf else {
                throw NotebookError.cannotGenerateTemplate(page.template)
            }
            var mediaBox = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
            let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) }
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary

            context.beginPDFPage(pageInfo)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            switch page.template {
            case .lined: drawLines(in: context, box: mediaBox)
            case .grid: drawGrid(in: context, box: mediaBox)
            case .dotted: drawDots(in: context, box: mediaBox)
            case .blank, .pdf: break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func drawLines(in context: CGContext, box: CGRect) {
        context.setStrokeColor(CGColor(red: 0.72, green: 0.80, blue: 0.90, alpha: 1))
        context.setLineWidth(0.6)
        let topMargin = 90.0, bottomMargin = 40.0, sideMargin = 36.0
        var y = box.maxY - topMargin
        while y >= bottomMargin {
            context.move(to: CGPoint(x: sideMargin, y: y))
            context.addLine(to: CGPoint(x: box.maxX - sideMargin, y: y))
            y -= lineSpacing
        }
        context.strokePath()
    }

    private static func drawGrid(in context: CGContext, box: CGRect) {
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.4)
        // Center the grid so the left/right and top/bottom leftovers are equal.
        let startX = box.width.truncatingRemainder(dividingBy: gridSpacing) / 2
        let startY = box.height.truncatingRemainder(dividingBy: gridSpacing) / 2
        for x in stride(from: startX, through: box.maxX, by: gridSpacing) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: box.maxY))
        }
        for y in stride(from: startY, through: box.maxY, by: gridSpacing) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: box.maxX, y: y))
        }
        context.strokePath()
    }

    private static func drawDots(in context: CGContext, box: CGRect) {
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        let radius = 0.9
        let startX = box.width.truncatingRemainder(dividingBy: gridSpacing) / 2 + gridSpacing
        let startY = box.height.truncatingRemainder(dividingBy: gridSpacing) / 2 + gridSpacing
        for x in stride(from: startX, to: box.maxX - gridSpacing + 0.1, by: gridSpacing) {
            for y in stride(from: startY, to: box.maxY - gridSpacing + 0.1, by: gridSpacing) {
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }
}
