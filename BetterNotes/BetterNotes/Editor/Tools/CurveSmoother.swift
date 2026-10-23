import CoreGraphics
import Foundation

/// A freehand stroke made smooth by holding the Pencil (M7b). Points are page coordinates.
nonisolated struct SmoothCurve: Equatable, Sendable {
    /// Dense points along the curve, from where the stroke started to where it was held.
    var points: [CGPoint]

    /// The curve after the Pencil moved from `hold` to `pencil` while still down: the start stays
    /// put and the end follows the Pencil, so the whole curve stretches and turns with it,
    /// keeping its shape (decided with the developer).
    func following(from hold: CGPoint, to pencil: CGPoint) -> SmoothCurve {
        guard let start = points.first else { return self }
        let before = hold - start, after = pencil - start
        let lengthBefore = hypot(before.x, before.y)
        guard lengthBefore > 0.001 else { return self }
        // Never shrink to nothing when the Pencil comes back to the start.
        let scale = max(hypot(after.x, after.y) / lengthBefore, CurveSmoother.minimumStretch)
        let angle = atan2(after.y, after.x) - atan2(before.y, before.x)
        return SmoothCurve(points: points.map { ($0 - start).rotated(by: angle).scaled(by: scale) + start })
    }

    var outline: ShapeOutline { ShapeOutline(pieces: [points], fill: nil, area: nil) }
}

/// Turns a shaky freehand stroke into a clean curve with few bends ("clean, few curves",
/// decided with the developer). Pure logic, tested.
///
/// Three steps: (1) the stroke is resampled evenly and averaged with its neighbours, which takes
/// out the shaking; (2) only the points where the curve really turns are kept (Ramer-Douglas-
/// Peucker: a point stays if leaving it out would move the line more than `tolerance`), which
/// takes out small bumps; (3) a centripetal Catmull-Rom spline is drawn through those points.
/// That spline passes through every kept point and, unlike the plain kind, never overshoots or
/// loops between close points.
nonisolated enum CurveSmoother {
    /// Smaller strokes are letters and short words, never smoothed (decided with the developer:
    /// about one line of the lined template).
    static let minimumSize: CGFloat = 30
    /// How far the clean curve may leave the averaged stroke: a fraction of its size, at least 2 pt.
    static let tolerance: CGFloat = 0.03
    static let minimumTolerance: CGFloat = 2
    /// Points per evenly spaced sample, and how many neighbours are averaged on each side.
    static let sampleSpacing: CGFloat = 2
    static let averagingRadius = 4
    /// Spacing of the points along the finished curve.
    static let outputSpacing: CGFloat = 2
    /// A stretched curve never gets shorter than this fraction of its drawn size.
    static let minimumStretch: CGFloat = 0.1

    static func smooth(_ points: [CGPoint]) -> SmoothCurve? {
        guard points.count >= 2 else { return nil }
        let length = Geometry.length(of: points)
        let box = Geometry.boundingBox(of: points)
        let size = hypot(box.width, box.height)
        guard size >= minimumSize, length >= minimumSize else { return nil }

        let count = max(Int(length / sampleSpacing), 8)
        let averaged = movingAverage(Geometry.resample(points, count: count), radius: averagingRadius)
        let key = simplify(averaged, tolerance: max(minimumTolerance, tolerance * size))
        return SmoothCurve(points: catmullRom(through: key, spacing: outputSpacing))
    }

    /// Each point replaced by the average of itself and `radius` neighbours on each side (fewer
    /// near the ends); the first and last point stay exactly where they were.
    static func movingAverage(_ points: [CGPoint], radius: Int) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = points
        for index in 1..<(points.count - 1) {
            let reach = min(radius, index, points.count - 1 - index)
            let window = points[(index - reach)...(index + reach)]
            result[index] = Geometry.centroid(of: Array(window))
        }
        return result
    }

    /// Ramer-Douglas-Peucker: keeps the points that matter for the shape within `tolerance`.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, distance: CGFloat = 0
            for index in (first + 1)..<last {
                let d = Geometry.distance(from: points[index], toSegment: points[first], points[last])
                if d > distance { distance = d; farthest = index }
            }
            if distance > tolerance {
                keep[farthest] = true
                ranges.append((first, farthest))
                ranges.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// A centripetal Catmull-Rom spline through `points`, as points about `spacing` apart.
    static func catmullRom(through points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        // The ends get a mirrored extra point, so the curve starts and ends in the drawn direction.
        let padded = [points[0] + (points[0] - points[1])] + points + [points[points.count - 1] + (points[points.count - 1] - points[points.count - 2])]
        var result: [CGPoint] = [points[0]]
        for index in 1..<(padded.count - 2) {
            let p0 = padded[index - 1], p1 = padded[index], p2 = padded[index + 1], p3 = padded[index + 2]
            let segment = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = max(Int(segment / spacing), 1)
            for step in 1...steps {
                result.append(centripetal(p0, p1, p2, p3, t: CGFloat(step) / CGFloat(steps)))
            }
        }
        return result
    }

    /// One point between `p1` and `p2` (t from 0 to 1) of the centripetal Catmull-Rom segment
    /// (Barry-Goldman form, knots spaced by the square root of the distance).
    private static func centripetal(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(sqrt(hypot(b.x - a.x, b.y - a.y)), 0.0001) }
        let t0: CGFloat = 0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        let u = t1 + (t2 - t1) * t
        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
            let w = (u - ta) / (tb - ta)
            return CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        let a1 = lerp(p0, p1, t0, t1), a2 = lerp(p1, p2, t1, t2), a3 = lerp(p2, p3, t2, t3)
        let b1 = lerp(a1, a2, t0, t2), b2 = lerp(a2, a3, t1, t3)
        return lerp(b1, b2, t1, t2)
    }
}

/// What a hold turned the stroke into: a clean shape (M7) or a smooth curve (M7b).
nonisolated enum SnapResult: Equatable, Sendable {
    case shape(SnappedShape)
    case curve(SmoothCurve)

    var outline: ShapeOutline {
        switch self {
        case .shape(let shape): shape.outline
        case .curve(let curve): curve.outline
        }
    }

    func following(from hold: CGPoint, to pencil: CGPoint) -> SnapResult {
        switch self {
        case .shape(let shape): .shape(shape.following(from: hold, to: pencil))
        case .curve(let curve): .curve(curve.following(from: hold, to: pencil))
        }
    }
}

nonisolated extension CGPoint {
    func scaled(by factor: CGFloat) -> CGPoint { CGPoint(x: x * factor, y: y * factor) }
}
