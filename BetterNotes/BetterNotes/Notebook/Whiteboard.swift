import CoreGraphics
import Foundation
import UIKit

/// The whiteboard's fixed numbers and the drawing that the screen, covers and export share
/// (see `docs/DECISIONS.md`, "Whiteboard, design" and "Whiteboard spike").
///
/// A whiteboard is a notebook with one big blank page. Its ink, objects and shapes use the
/// same page coordinates as any page (points, top-left origin, y down).
nonisolated enum Whiteboard {
    /// The board: 10000 x 10000 pt (below PDF's limit of 14400 pt).
    static let size = PageSize(width: 10_000, height: 10_000)
    static var bounds: CGRect { CGRect(x: 0, y: 0, width: size.width, height: size.height) }

    /// Zooming out further made PencilKit hold the ink of the whole board in memory (spike:
    /// about 130 KB per visible stroke, 2.8 GB at 20000 strokes). At 0.5 the screen shows four
    /// screens' worth of board.
    static let minimumZoom: CGFloat = 0.5
    static let maximumZoom: CGFloat = 5

    /// Space between dots and grid lines, in points.
    static let patternSpacing: CGFloat = 32
    /// Around the ink in exports and covers.
    static let margin: CGFloat = 60

    /// What a cover or an export shows: everything drawn or placed, with a margin, inside the
    /// board. An empty board gives an A4-sized area in its middle.
    static func contentRegion(inkBounds: CGRect, objects: [PageObject]) -> CGRect {
        var region = inkBounds.isNull || inkBounds.isEmpty ? CGRect.null : inkBounds
        for object in objects { region = region.union(object.frame) }
        guard !region.isNull else {
            let a4 = PageSize.a4Portrait
            return CGRect(x: (size.width - a4.width) / 2, y: (size.height - a4.height) / 2, width: a4.width, height: a4.height)
        }
        return region.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral
    }

    /// Pixels per point for ink in an export of `region`: normally `preferred` (4, like
    /// notebooks), lower for big regions so one ink picture stays under `maximumPixels`
    /// (a full board at 4 px per point would be 40000 x 40000 px, several GB).
    static func inkScale(for region: CGRect, preferred: CGFloat, maximumPixels: CGFloat = 64_000_000) -> CGFloat {
        let area = region.width * region.height
        guard area > 0 else { return preferred }
        return max(0.5, min(preferred, (maximumPixels / area).squareRoot()))
    }

    /// Draws the background pattern for `rect` (page points) into `context`, which draws in page
    /// points. Dots and grid lines sit in the middle of each `patternSpacing` square (at 16, 48,
    /// 80, ...), so one square is a tile that repeats without cutting a dot (see `patternTile`).
    static func drawBackground(_ background: BoardBackground, in rect: CGRect, context: CGContext) {
        let spacing = patternSpacing
        let half = spacing / 2
        let firstX = ((rect.minX - half) / spacing).rounded(.up) * spacing + half
        let firstY = ((rect.minY - half) / spacing).rounded(.up) * spacing + half
        switch background {
        case .plain:
            return
        case .dots:
            context.setFillColor(UIColor(white: 0.72, alpha: 1).cgColor)
            let radius: CGFloat = 1.3
            var y = firstY
            while y <= rect.maxY {
                var x = firstX
                while x <= rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
        case .grid:
            context.setStrokeColor(UIColor(red: 0.78, green: 0.84, blue: 0.92, alpha: 1).cgColor)
            context.setLineWidth(0.6)
            var x = firstX
            while x <= rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += spacing
            }
            var y = firstY
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
        }
    }

    /// One tile of the pattern (one spacing square), for a repeating pattern color on screen.
    static func patternTile(_ background: BoardBackground, scale: CGFloat) -> UIImage? {
        guard background != .plain else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let size = CGSize(width: patternSpacing, height: patternSpacing)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drawBackground(background, in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
    }
}
