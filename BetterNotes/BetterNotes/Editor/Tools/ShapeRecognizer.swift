import CoreGraphics
import Foundation

/// A clean shape that a held stroke snapped to (M7). Points are page coordinates.
///
/// Every shape keeps an `angle`: its own "upright" direction. Resizing while the Pencil is
/// still down (`following`) happens in that turned frame, so a rectangle drawn at an angle
/// keeps its angle and only gets wider or taller along its own sides.
nonisolated struct SnappedShape: Equatable, Sendable {
    var kind: ShapeKind
    /// Line: start and end. Triangle: 3 corners. Rectangle: 4 corners. Ellipse: the 4 corners
    /// of the turned box it fills.
    var corners: [CGPoint]
    /// Radians. The direction of the box's sides (rectangle, ellipse) or of the triangle's
    /// base; 0 = upright on the page. Unused for lines.
    var angle: CGFloat

    /// The points to draw: open for a line, closed (first point repeated) for the others.
    var path: [CGPoint] {
        switch kind {
        case .line:
            return corners
        case .rectangle, .triangle:
            return corners + [corners[0]]
        case .ellipse:
            let local = corners.map { $0.rotated(by: -angle) }
            return ShapeGeometry.ellipse(in: Geometry.boundingBox(of: local)).map { $0.rotated(by: angle) }
        }
    }

    /// What the preview and the strokes draw: one solid piece, corners kept sharp.
    var outline: ShapeOutline {
        let points = path
        return ShapeOutline(pieces: [kind == .ellipse ? points : ShapeGeometry.sharpened(points)], fill: nil, area: nil)
    }

    /// The shape after the Pencil moved from `hold` (where it was held) to `pencil`, while
    /// still down. A line's end follows the Pencil (longer, shorter, turned). The other shapes
    /// are resized in their own frame: the side away from the held point stays put, the side
    /// near it follows. Sizes never shrink below `ShapeRecognizer.minimumFollowSize`.
    func following(from hold: CGPoint, to pencil: CGPoint) -> SnappedShape {
        var result = self
        if kind == .line {
            result.corners[1] = ShapeRecognizer.snappedLineEnd(from: corners[0], to: pencil)
            return result
        }
        let local = corners.map { $0.rotated(by: -angle) }
        let box = Geometry.boundingBox(of: local)
        let holdLocal = hold.rotated(by: -angle)
        let pencilLocal = pencil.rotated(by: -angle)
        // The anchor is the box edge on the other side of the center from the held point.
        let anchor = CGPoint(x: holdLocal.x >= box.midX ? box.minX : box.maxX,
                             y: holdLocal.y >= box.midY ? box.minY : box.maxY)
        func scale(_ from: CGFloat, _ to: CGFloat, _ anchor: CGFloat, size: CGFloat) -> CGFloat {
            let start = from - anchor
            guard abs(start) > 0.001 else { return 1 }
            let factor = (to - anchor) / start
            // Never flip over or collapse to nothing.
            return max(factor, ShapeRecognizer.minimumFollowSize / max(size, 0.001))
        }
        let sx = scale(holdLocal.x, pencilLocal.x, anchor.x, size: box.width)
        let sy = scale(holdLocal.y, pencilLocal.y, anchor.y, size: box.height)
        result.corners = local.map {
            CGPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy).rotated(by: angle)
        }
        return result
    }
}

/// Decides which clean shape a stroke was meant to be: line, rectangle, ellipse, triangle, or
/// nothing. Pure logic, tested with shaky and turned shapes and with handwriting.
///
/// How: the stroke is first resampled to evenly spaced points. An open stroke is a line if it
/// stays close to the straight line between its ends. A closed stroke is compared with three
/// fitted models (the smallest turned box around it as rectangle, the ellipse in that box, the
/// biggest triangle through its outer points); the model with the smallest average distance
/// to the stroke wins, if that distance is small enough. Strokes that loop around more than
/// once, are small like a letter or fit no model well return nil, so writing is left alone.
nonisolated enum ShapeRecognizer {
    /// Smaller strokes are letters, not shapes.
    static let minimumSize: CGFloat = 15
    /// A closed stroke's ends are at most this fraction of its size apart.
    static let closedGap: CGFloat = 0.25
    /// A line may wander this far from straight: a fraction of its length, at least `lineMinDeviation`.
    static let lineDeviation: CGFloat = 0.06
    static let lineMinDeviation: CGFloat = 2.5
    /// The best model's average distance to the stroke, as a fraction of the stroke's size.
    static let maximumFitError: CGFloat = 0.04
    /// A closed stroke much longer than the shape's outline went around more than once.
    static let maximumLengthRatio: CGFloat = 1.35
    /// Angles this close to horizontal or vertical become exact (decided with the developer).
    static let lineSnapAngle: CGFloat = 5 * .pi / 180
    static let boxSnapAngle: CGFloat = 8 * .pi / 180
    /// A shape being resized never gets smaller than this.
    static let minimumFollowSize: CGFloat = 4
    /// Points the stroke is resampled to.
    static let sampleCount = 64

    static func recognize(_ points: [CGPoint]) -> SnappedShape? {
        guard points.count >= 2 else { return nil }
        let length = Geometry.length(of: points)
        let box = Geometry.boundingBox(of: points)
        let size = hypot(box.width, box.height)
        guard size >= minimumSize, length > 0 else { return nil }
        let samples = Geometry.resample(points, count: sampleCount)

        let gap = hypot(points[0].x - points.last!.x, points[0].y - points.last!.y)
        if gap > closedGap * size {
            return line(samples, length: length)
        }
        return closedShape(samples, size: size, length: length)
    }

    // MARK: Line

    private static func line(_ samples: [CGPoint], length: CGFloat) -> SnappedShape? {
        let start = samples[0], end = samples.last!
        let chord = hypot(end.x - start.x, end.y - start.y)
        guard chord >= minimumSize, length <= chord * 1.2 else { return nil }
        let deviation = samples.map { Geometry.distance(from: $0, toSegment: start, end) }.max() ?? 0
        guard deviation <= max(lineMinDeviation, lineDeviation * chord) else { return nil }
        return SnappedShape(kind: .line, corners: [start, snappedLineEnd(from: start, to: end)], angle: 0)
    }

    /// `end`, moved onto the exact horizontal or vertical through `start` when the line is
    /// within `lineSnapAngle` of it; the length stays.
    static func snappedLineEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let angle = atan2(dy, dx)
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        guard abs(angle - nearest) <= lineSnapAngle else { return end }
        return CGPoint(x: start.x + cos(nearest) * length, y: start.y + sin(nearest) * length)
    }

    // MARK: Closed shapes

    private static func closedShape(_ samples: [CGPoint], size: CGFloat, length: CGFloat) -> SnappedShape? {
        let hull = Geometry.convexHull(samples)
        guard hull.count >= 3 else { return nil }
        let frame = Geometry.minimumAreaBox(hull)
        guard frame.width > 0.1 * size, frame.height > 0.1 * size else { return nil }  // flat: a line drawn back and forth

        let rectangle = boxShape(.rectangle, frame)
        let ellipse = boxShape(.ellipse, frame)
        let candidates = [rectangle, ellipse, triangle(hull)].compactMap { $0 }

        var best: (shape: SnappedShape, error: CGFloat)?
        for shape in candidates {
            let outline = shape.path
            let perimeter = Geometry.length(of: outline)
            guard perimeter > 0, length <= perimeter * maximumLengthRatio else { continue }
            let error = samples.map { Geometry.distance(from: $0, toPolyline: outline) }.reduce(0, +)
                / CGFloat(samples.count) / size
            if error < (best?.error ?? .infinity) { best = (shape, error) }
        }
        guard let best, best.error <= maximumFitError else { return nil }
        return snapped(best.shape)
    }

    private static func boxShape(_ kind: ShapeKind, _ frame: Geometry.TurnedBox) -> SnappedShape {
        SnappedShape(kind: kind, corners: frame.corners, angle: frame.angle)
    }

    /// The biggest triangle through three of the outer points.
    private static func triangle(_ hull: [CGPoint]) -> SnappedShape? {
        // Fewer hull points keep the search small; the hull of 64 samples is rarely bigger.
        let points = hull.count > 40 ? stride(from: 0, to: hull.count, by: 2).map { hull[$0] } : hull
        var best: (area: CGFloat, corners: [CGPoint])?
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                for k in (j + 1)..<points.count {
                    let a = points[i], b = points[j], c = points[k]
                    let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
                    if area > (best?.area ?? 0) { best = (area, [a, b, c]) }
                }
            }
        }
        guard let corners = best?.corners else { return nil }
        // The base is the side closest to horizontal.
        let sides = (0..<3).map { index -> CGFloat in
            let a = corners[index], b = corners[(index + 1) % 3]
            return Geometry.angleFromHorizontal(b.x - a.x, b.y - a.y)
        }
        let base = sides.min(by: { abs($0) < abs($1) }) ?? 0
        return SnappedShape(kind: .triangle, corners: corners, angle: base)
    }

    /// Turns a shape that is almost upright to exactly upright (around its center).
    private static func snapped(_ shape: SnappedShape) -> SnappedShape {
        guard shape.angle != 0, abs(shape.angle) <= boxSnapAngle else { return shape }
        let center = Geometry.centroid(of: shape.corners)
        var result = shape
        result.corners = shape.corners.map { ($0 - center).rotated(by: -shape.angle) + center }
        result.angle = 0
        return result
    }
}

// MARK: - Geometry helpers

nonisolated enum Geometry {
    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func centroid(of points: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// `count` points evenly spaced along the stroke, first and last kept.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = length(of: points)
        guard total > 0, count >= 2 else { return points }
        let step = total / CGFloat(count - 1)
        var result = [points[0]]
        var carried: CGFloat = 0  // distance walked since the last sample
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = hypot(b.x - a.x, b.y - a.y)
            guard segment > 0 else { continue }
            var position = step - carried
            while position <= segment, result.count < count - 1 {
                let t = position / segment
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                position += step
            }
            carried = segment - (position - step)
        }
        result.append(points.last!)
        return result
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).map { distance(from: p, toSegment: $0.0, $0.1) }.min() ?? .infinity
    }

    /// The angle of a direction folded into -45...45 degrees: how far it is turned from the
    /// nearest horizontal or vertical.
    static func angleFromHorizontal(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
        var angle = atan2(dy, dx)
        let quarter = CGFloat.pi / 2
        angle -= (angle / quarter).rounded() * quarter
        return angle
    }

    /// The convex hull (Andrew's monotone chain), counter-clockwise, without repeats.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A box turned by `angle` (radians, -45...45 degrees) around nothing in particular: its
    /// corners are what counts.
    struct TurnedBox {
        var corners: [CGPoint]
        var angle: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    /// The smallest box (any angle) around a convex hull. One of its sides always lies on a
    /// hull edge, so it is enough to try each edge's angle.
    static func minimumAreaBox(_ hull: [CGPoint]) -> TurnedBox {
        var best: (area: CGFloat, box: TurnedBox)?
        for (a, b) in zip(hull, hull.dropFirst() + [hull[0]]) {
            let angle = angleFromHorizontal(b.x - a.x, b.y - a.y)
            let local = boundingBox(of: hull.map { $0.rotated(by: -angle) })
            let area = local.width * local.height
            if area < (best?.area ?? .infinity) {
                let corners = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                               CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)]
                    .map { $0.rotated(by: angle) }
                best = (area, TurnedBox(corners: corners, angle: angle, width: local.width, height: local.height))
            }
        }
        return best!.box
    }
}

nonisolated extension CGPoint {
    /// This point turned around the origin by `angle` radians (clockwise on screen, y down).
    func rotated(by angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}
