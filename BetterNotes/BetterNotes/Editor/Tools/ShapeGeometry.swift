import CoreGraphics
import PencilKit
import UIKit

/// The shapes the shape tool draws (and that M7 will recognize).
nonisolated enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case line, rectangle, ellipse, triangle

    var displayName: String {
        switch self {
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        }
    }

    var symbol: String {
        switch self {
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        }
    }

    /// A line has no inside to fill.
    var canBeFilled: Bool { self != .line }
}

/// One shape as it will be drawn: the outline pieces and, when filled, one zigzag that covers
/// the inside. Points are in page coordinates (top-left origin, y down). The preview layer draws
/// these same points, so what is previewed is what is committed.
nonisolated struct ShapeOutline: Equatable, Sendable {
    /// Each piece becomes one stroke: one for solid, many for dashed or dotted.
    var pieces: [[CGPoint]]
    /// A single stroke that zigzags across the inside, or nil (not filled, a line, or too small).
    var fill: [CGPoint]?
}

/// Pure geometry for the shape tool, tested without a screen.
///
/// PencilKit smooths a stroke's control points into a curve (measured: a rectangle given only
/// its corners came out with edges bowed inward). A point that is repeated three times makes
/// the curve pass through it with a sharp corner, and between two such points the stroke is
/// straight. So corners and the turns of the fill are repeated (`sharpened`).
nonisolated enum ShapeGeometry {
    /// Points along an ellipse; enough that the smoothing makes it round, not a polygon.
    static let ellipseSegments = 72
    /// The fill is one wide stroke, laid in rows that overlap a little so no gaps show.
    static let fillWidth: CGFloat = 8
    static let fillRowSpacing: CGFloat = 6
    /// The fill is the shape's color at this opacity, so the outline and writing on top stay visible.
    static let fillOpacity: CGFloat = 0.25
    /// A drag shorter than this (a tap) draws nothing.
    static let minimumSize: CGFloat = 2

    /// The shape in the box spanned by a drag from `start` to `end`: a line goes from start to
    /// end; rectangle, ellipse and triangle fill the box (the triangle points up).
    /// The polygon is closed (first point repeated at the end); a line has two points.
    static func path(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        if kind == .line { return [start, end] }
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch kind {
        case .line:
            return [start, end]
        case .rectangle:
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                    CGPoint(x: box.minX, y: box.minY)]
        case .triangle:
            let apex = CGPoint(x: box.midX, y: box.minY)
            return [apex, CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), apex]
        case .ellipse:
            return ellipse(in: box)
        }
    }

    /// An ellipse starting at the top and going clockwise, closed.
    static func ellipse(in box: CGRect) -> [CGPoint] {
        let points = (0..<ellipseSegments).map { index in
            let angle = CGFloat(index) / CGFloat(ellipseSegments) * 2 * .pi - .pi / 2
            return CGPoint(x: box.midX + cos(angle) * box.width / 2, y: box.midY + sin(angle) * box.height / 2)
        }
        return points + [points[0]]  // exactly closed (2 pi in floating point is not)
    }

    /// Everything to draw for one drag. `width` is the outline's pen width.
    static func outline(
        _ kind: ShapeKind, from start: CGPoint, to end: CGPoint, style: LineStyle, width: CGFloat, filled: Bool
    ) -> ShapeOutline? {
        guard hypot(end.x - start.x, end.y - start.y) >= minimumSize else { return nil }
        let points = path(kind, from: start, to: end)
        let sharp = kind != .ellipse  // an ellipse has no corners
        let pieces = LineDasher.pieces(of: points, style: style, width: width).map { sharp ? sharpened($0) : $0 }
        let fill = filled && kind.canBeFilled ? fillZigzag(kind, from: start, to: end) : nil
        return ShapeOutline(pieces: pieces, fill: fill)
    }

    /// Repeats every point three times, so PencilKit's smoothing keeps corners sharp and
    /// edges straight (see the type comment).
    static func sharpened(_ points: [CGPoint]) -> [CGPoint] {
        points.flatMap { [$0, $0, $0] }
    }

    // MARK: Fill

    /// One zigzag through the inside: rows from top to bottom, alternating direction, each row
    /// clipped to the shape shrunk by half the fill width, so the fill's edge ends under the
    /// outline instead of sticking out. All shapes are convex, so the short connections
    /// between rows stay inside too. Nil when the shape is too small for a row.
    static func fillZigzag(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint) -> [CGPoint]? {
        guard kind.canBeFilled else { return nil }
        let inset = fillWidth / 2
        guard let polygon = insetPolygon(kind, from: start, to: end, by: inset) else { return nil }
        let top = polygon.map(\.y).min()!, bottom = polygon.map(\.y).max()!
        var rows: [CGFloat] = []
        var y = top
        while y < bottom { rows.append(y); y += fillRowSpacing }
        rows.append(bottom)

        var points: [CGPoint] = []
        var leftToRight = true
        for rowY in rows {
            guard let span = span(of: polygon, atY: rowY) else { continue }
            let row = [CGPoint(x: span.lowerBound, y: rowY), CGPoint(x: span.upperBound, y: rowY)]
            points += leftToRight ? row : row.reversed()
            leftToRight.toggle()
        }
        return points.isEmpty ? nil : sharpened(points)
    }

    /// The shape shrunk by `inset` on every side, as a closed convex polygon, or nil when
    /// nothing is left.
    static func insetPolygon(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint, by inset: CGFloat) -> [CGPoint]? {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch kind {
        case .line:
            return nil
        case .rectangle, .ellipse:
            let inner = box.insetBy(dx: inset, dy: inset)
            guard inner.width > 0, inner.height > 0 else { return nil }
            return kind == .rectangle ? path(.rectangle, from: inner.origin, to: CGPoint(x: inner.maxX, y: inner.maxY))
                : ellipse(in: inner)
        case .triangle:
            // Moving every side of a triangle inward by the same distance gives the same
            // triangle, scaled down around its incenter (the center of the inscribed circle).
            let corners = Array(path(.triangle, from: start, to: end).prefix(3))
            let (a, b, c) = (corners[0], corners[1], corners[2])
            let la = hypot(b.x - c.x, b.y - c.y), lb = hypot(a.x - c.x, a.y - c.y), lc = hypot(a.x - b.x, a.y - b.y)
            let perimeter = la + lb + lc
            guard perimeter > 0 else { return nil }
            let center = CGPoint(x: (la * a.x + lb * b.x + lc * c.x) / perimeter,
                                 y: (la * a.y + lb * b.y + lc * c.y) / perimeter)
            let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            let inradius = 2 * area / perimeter
            guard inradius > inset else { return nil }
            let factor = (inradius - inset) / inradius
            let scaled = corners.map { CGPoint(x: center.x + ($0.x - center.x) * factor, y: center.y + ($0.y - center.y) * factor) }
            return scaled + [scaled[0]]
        }
    }

    /// Where the horizontal line at `y` enters and leaves a closed convex polygon.
    static func span(of polygon: [CGPoint], atY y: CGFloat) -> ClosedRange<CGFloat>? {
        var xs: [CGFloat] = []
        for index in 1..<polygon.count {
            let p = polygon[index - 1], q = polygon[index]
            let low = min(p.y, q.y), high = max(p.y, q.y)
            guard y >= low, y <= high else { continue }
            if high - low < 0.0001 {
                xs += [p.x, q.x]  // a horizontal edge at exactly this height
            } else {
                xs.append(p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x))
            }
        }
        guard let low = xs.min(), let high = xs.max() else { return nil }
        return low...high
    }

    // MARK: Strokes

    /// The strokes for a shape: the fill first (so it lies under the outline), then the outline.
    /// Shapes use the pen ink: its width stays even with these fixed points, and unlike the
    /// monoline ink it allows wide lines (monoline stops at 4 pt).
    static func strokes(for shape: ShapeOutline, color: UIColor, width: CGFloat) -> [PKStroke] {
        var strokes: [PKStroke] = []
        if let fill = shape.fill {
            let ink = PKInk(.pen, color: color.withAlphaComponent(fillOpacity))
            strokes.append(LineDasher.stroke(through: fill, ink: ink, width: fillWidth))
        }
        let ink = PKInk(.pen, color: color)
        strokes += shape.pieces.map { LineDasher.stroke(through: $0, ink: ink, width: width) }
        return strokes
    }
}
