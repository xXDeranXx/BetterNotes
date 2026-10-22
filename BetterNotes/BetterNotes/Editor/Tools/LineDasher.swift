import CoreGraphics
import PencilKit

/// How a line or shape outline is drawn. PencilKit ink is always solid, so dashes and dots
/// are made of many short strokes (SPEC, "M7a, decisions").
nonisolated enum LineStyle: String, Codable, CaseIterable, Sendable {
    case solid, dashed, dotted
}

/// Cuts a path into the pieces that make a dashed or dotted line, and builds `PKStroke`s.
/// Pure geometry, so it is tested without a screen.
nonisolated enum LineDasher {
    /// The visible pieces of the polyline `points` for `style` and pen `width`, each a short
    /// list of points. Solid returns the whole line as one piece. Lengths scale with the
    /// width so a thick pen gets proportionally longer dashes: dash 4x width and gap 3x width;
    /// a dot is a piece of almost no length (the round pen tip makes it a dot) with a gap of 2.5x width.
    static func pieces(of points: [CGPoint], style: LineStyle, width: CGFloat) -> [[CGPoint]] {
        guard points.count >= 2 else { return points.isEmpty ? [] : [points] }
        let on: CGFloat, off: CGFloat
        switch style {
        case .solid: return [points]
        case .dashed: (on, off) = (max(width * 4, 4), max(width * 3, 3))
        case .dotted: (on, off) = (0.5, max(width * 2.5, 3))
        }

        var pieces: [[CGPoint]] = []
        var current: [CGPoint] = []
        var drawing = true
        var remaining = on  // how much of the current dash or gap is left
        current.append(points[0])

        for index in 1..<points.count {
            var start = points[index - 1]
            let end = points[index]
            var segment = hypot(end.x - start.x, end.y - start.y)
            guard segment > 0 else { continue }
            let direction = CGPoint(x: (end.x - start.x) / segment, y: (end.y - start.y) / segment)
            while segment > remaining {
                let cut = CGPoint(x: start.x + direction.x * remaining, y: start.y + direction.y * remaining)
                if drawing {
                    current.append(cut)
                    pieces.append(current)
                    current = []
                } else {
                    current = [cut]
                }
                segment -= remaining
                start = cut
                drawing.toggle()
                remaining = drawing ? on : off
            }
            remaining -= segment
            if drawing { current.append(end) }
        }
        if drawing, current.count >= 2 { pieces.append(current) }
        return pieces
    }

    /// One `PKStroke` through `points`, in the given ink and width. A piece of a single point
    /// or of zero length still makes a dot, because the pen tip is round.
    static func stroke(through points: [CGPoint], ink: PKInk, width: CGFloat, start: Date = .now) -> PKStroke {
        let size = CGSize(width: width, height: width)
        var distance: CGFloat = 0
        var controlPoints: [PKStrokePoint] = []
        // PencilKit needs at least two distinct control points to show anything.
        let source = points.count >= 2 ? points : [points[0], CGPoint(x: points[0].x + 0.01, y: points[0].y)]
        for (index, location) in source.enumerated() {
            if index > 0 { distance += hypot(location.x - source[index - 1].x, location.y - source[index - 1].y) }
            controlPoints.append(PKStrokePoint(
                location: location, timeOffset: TimeInterval(distance) / 1000, size: size, opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: start))
    }

    /// All strokes of a line or outline in `style`: one stroke for solid, many for dashed and dotted.
    static func strokes(through points: [CGPoint], style: LineStyle, ink: PKInk, width: CGFloat) -> [PKStroke] {
        pieces(of: points, style: style, width: width).map { stroke(through: $0, ink: ink, width: width) }
    }
}
