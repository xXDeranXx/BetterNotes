import CoreGraphics
import Foundation
import Testing
@testable import BetterNotes

/// Seeded jitter, so every run is the same.
private struct Jitter {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 11) / Double(1 << 53)) * 2 - 1
    }
}

/// A wave 200 pt long, drawn with a shaking hand (every 1 pt, up to `shake` off).
private func shakyWave(shake: CGFloat, seed: UInt64 = 1) -> (drawn: [CGPoint], intended: (CGFloat) -> CGFloat) {
    var jitter = Jitter(state: seed)
    let intended: (CGFloat) -> CGFloat = { x in 100 + 30 * sin(x / 200 * 2 * .pi) }
    let drawn = stride(from: CGFloat(0), through: 200, by: 1).map { x in
        CGPoint(x: x + jitter.next() * shake, y: intended(x) + jitter.next() * shake)
    }
    return (drawn, intended)
}

/// How much a path turns in total (radians): shaking makes it turn back and forth a lot.
private func totalTurning(_ points: [CGPoint]) -> CGFloat {
    var total: CGFloat = 0
    for i in 1..<(points.count - 1) {
        let a = atan2(points[i].y - points[i - 1].y, points[i].x - points[i - 1].x)
        let b = atan2(points[i + 1].y - points[i].y, points[i + 1].x - points[i].x)
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        total += abs(d)
    }
    return total
}

struct CurveSmootherTests {
    @Test func aShakyWaveBecomesSmoothAndStaysCloseToWhatWasMeant() throws {
        let (drawn, intended) = shakyWave(shake: 2)
        let curve = try #require(CurveSmoother.smooth(drawn))
        // Close to the intended wave everywhere (the shaking was up to 2 pt).
        for point in curve.points where point.x > 5 && point.x < 195 {
            #expect(abs(point.y - intended(point.x)) < 5, "at x \(point.x)")
        }
        // Far less back and forth than the drawn stroke; a clean sine of one period turns about 3 rad.
        #expect(totalTurning(curve.points) < 6)
        #expect(totalTurning(drawn) > 20)
    }

    @Test func theCurveStartsAndEndsWhereTheStrokeDid() throws {
        let (drawn, _) = shakyWave(shake: 1.5, seed: 2)
        let curve = try #require(CurveSmoother.smooth(drawn))
        #expect(curve.points.first == drawn.first)
        #expect(curve.points.last == drawn.last)
    }

    @Test func pointsAlongTheCurveAreDenseSoPencilKitDrawsItRound() throws {
        let curve = try #require(CurveSmoother.smooth(shakyWave(shake: 1).drawn))
        let gaps = zip(curve.points, curve.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect((gaps.max() ?? 0) < 4)
    }

    @Test func aBigBendDrawnOnPurposeStays() throws {
        // An L-like hook: down 120 pt, then right 120 pt. Smoothing may round the corner, but not cut it off.
        let points = stride(from: CGFloat(0), through: 120, by: 1).map { CGPoint(x: 0, y: $0) }
            + stride(from: CGFloat(1), through: 120, by: 1).map { CGPoint(x: $0, y: 120) }
        let curve = try #require(CurveSmoother.smooth(points))
        let nearCorner = curve.points.map { hypot($0.x, $0.y - 120) }.min() ?? .infinity
        #expect(nearCorner < 6)
    }

    @Test func lettersAndShortWordsAreNeverSmoothed() {
        // A loop 20 pt tall, like a handwritten "l" or "e".
        let letter = (0...60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * 2 * .pi
            return CGPoint(x: 10 + 6 * sin(t), y: 20 - 10 * (1 - cos(t)))
        }
        #expect(CurveSmoother.smooth(letter) == nil)
        #expect(CurveSmoother.smooth([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 5)]) == nil)
    }

    @Test func whileHeldTheEndFollowsAndTheCurveStretchesKeepingItsShape() throws {
        let curve = SmoothCurve(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 20), CGPoint(x: 100, y: 0)])
        let moved = curve.following(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 200))
        #expect(moved.points[0] == CGPoint(x: 0, y: 0))  // the start stays
        #expect(abs(moved.points[2].x) < 0.001 && abs(moved.points[2].y - 200) < 0.001)  // the end is at the Pencil
        // Turned by 90 degrees and twice as big: the bump at (50, 20) is now at (-40, 100).
        #expect(abs(moved.points[1].x + 40) < 0.001 && abs(moved.points[1].y - 100) < 0.001)
    }

    @Test func aStretchedCurveNeverShrinksToNothing() {
        let curve = SmoothCurve(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        let moved = curve.following(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 0))
        #expect(hypot(moved.points[1].x, moved.points[1].y) >= 100 * CurveSmoother.minimumStretch - 0.001)
    }

    @Test func smoothingIsOnByDefaultAlsoForOldSettings() throws {
        #expect(ToolSettings().holdToSmoothCurves)
        #expect(try JSONDecoder().decode(ToolSettings.self, from: Data("{}".utf8)).holdToSmoothCurves)
    }
}
