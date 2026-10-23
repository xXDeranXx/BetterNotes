import CoreGraphics
import PencilKit

/// How the points of a snapped shape are drawn, so it looks like the user's own writing with
/// the same pen (M7).
///
/// Measured (2026-10-23, saved strokes from the simulator): PencilKit does not store a pen's
/// width as the point size. Each ink has its own rule (a highlighter of width 20 has point size
/// 13.3, a pencil of width 6 has 1.94), pencil and brush points are partly see-through
/// (opacity 0.39 and 0.17), and the plain pen's thickness comes mostly from the Pencil's
/// pressure, which the simulator does not have. So instead of a table, the shape copies the
/// points of the **last stroke the user drew with the same pen and width** (`from(_:)`): its
/// size, opacity, pressure and tilt. The table (`fallback`) is only used before the user has
/// written anything with that pen since the notebook was opened.
nonisolated struct InkTemplate: Equatable, Sendable {
    var size: CGSize
    var opacity: CGFloat
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat

    /// The typical point of a stroke: the median by size, so the thin start and end of a stroke
    /// and a single fat blot do not count.
    static func from(_ stroke: PKStroke) -> InkTemplate? {
        let points = Array(stroke.path)
        guard !points.isEmpty else { return nil }
        let median = points.sorted { $0.size.width < $1.size.width }[points.count / 2]
        return InkTemplate(size: median.size, opacity: median.opacity, force: median.force,
                           azimuth: median.azimuth, altitude: median.altitude)
    }

    /// A best guess from the measurements, for a pen not used yet. Upright Pencil, medium
    /// pressure; the azimuth of a horizontal stroke (the highlighter's and fountain pen's nib
    /// then draws its full width across a horizontal line).
    static func fallback(for ink: PKInkingTool.InkType, width: CGFloat) -> InkTemplate {
        let size: CGFloat
        var opacity: CGFloat = 1
        switch ink {
        case .pen, .monoline: size = LineDasher.pointSize(forWidth: width)  // measured in M7a: draws `width`
        case .fountainPen: size = width
        case .watercolor: size = width * 0.53; opacity = 0.17
        case .crayon: size = width * 0.7
        case .pencil: size = width * 0.27; opacity = 0.39
        case .marker: size = width / 1.5
        default: size = LineDasher.pointSize(forWidth: width)
        }
        return InkTemplate(size: CGSize(width: size, height: size), opacity: opacity, force: 1,
                           azimuth: .pi / 2, altitude: .pi / 2)
    }

    /// One stroke through `points` whose every point looks like this template.
    func stroke(through points: [CGPoint], ink: PKInk, start: Date = .now) -> PKStroke {
        // PencilKit needs at least two distinct control points to show anything.
        let source = points.count >= 2 ? points : [points[0], CGPoint(x: points[0].x + 0.01, y: points[0].y)]
        var distance: CGFloat = 0
        let controlPoints = source.enumerated().map { index, location -> PKStrokePoint in
            if index > 0 { distance += hypot(location.x - source[index - 1].x, location.y - source[index - 1].y) }
            return PKStrokePoint(location: location, timeOffset: TimeInterval(distance) / 1000, size: size,
                                 opacity: opacity, force: force, azimuth: azimuth, altitude: altitude)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: start))
    }
}
