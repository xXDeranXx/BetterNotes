import CoreGraphics
import Foundation

/// Notices when the Pencil stays still while it is down (M7, "hold to snap"). Pure logic: it
/// gets positions with their times and is asked "holding now?" by a timer, because a Pencil
/// that does not move may send no new touches at all.
///
/// Positions are in **screen points** (the window's coordinates), not page points: a still
/// hand is still on the glass, whatever the zoom. At 4x zoom, 4 page points would be 16 points
/// on the glass, and holding would feel different at every zoom level.
nonisolated struct HoldDetector: Sendable {
    /// How long the Pencil must stay still (SPEC: about 0.5 s).
    static let duration: TimeInterval = 0.5
    /// How far it may wander and still count as still (the spike used under 4 points).
    static let radius: CGFloat = 4

    /// Where the Pencil came to rest, and when. Moving further than `radius` from it starts over.
    private(set) var restPoint: CGPoint?
    private(set) var restTime: TimeInterval = 0

    mutating func add(_ point: CGPoint, at time: TimeInterval) {
        if let restPoint, hypot(point.x - restPoint.x, point.y - restPoint.y) <= Self.radius { return }
        restPoint = point
        restTime = time
    }

    func isHolding(at now: TimeInterval) -> Bool {
        restPoint != nil && now - restTime >= Self.duration
    }

    /// When a hold would be reached if the Pencil stays where it is now (for the timer).
    var holdTime: TimeInterval? { restPoint == nil ? nil : restTime + Self.duration }

    mutating func reset() {
        restPoint = nil
        restTime = 0
    }
}
