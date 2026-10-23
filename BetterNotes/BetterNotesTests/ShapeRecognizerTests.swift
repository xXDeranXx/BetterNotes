import CoreGraphics
import Foundation
import Testing
@testable import BetterNotes

/// Strokes made up in code, with a shaky hand (seeded, so every run is the same).
private struct Hand {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// A number between -1 and 1.
    mutating func wobble() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 11) / Double(1 << 53)) * 2 - 1
    }

    /// Points along `corners` (in order) every ~2 pt, each pushed off by up to `shake`.
    mutating func stroke(through corners: [CGPoint], shake: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        var drift = CGPoint.zero  // a slow wander, like a real hand
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / 2), 1)
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                drift = CGPoint(x: drift.x * 0.9 + wobble() * shake * 0.3, y: drift.y * 0.9 + wobble() * shake * 0.3)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + drift.x + wobble() * shake * 0.3,
                                      y: a.y + (b.y - a.y) * t + drift.y + wobble() * shake * 0.3))
            }
        }
        points.append(corners.last!)
        return points
    }

    mutating func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, turns: CGFloat = 1.05, angle: CGFloat = 0, shake: CGFloat) -> [CGPoint] {
        let count = Int(80 * turns)
        let corners = (0...count).map { index -> CGPoint in
            let t = CGFloat(index) / CGFloat(count) * turns * 2 * .pi - .pi / 2
            return CGPoint(x: cos(t) * rx, y: sin(t) * ry).rotated(by: angle) + center
        }
        return stroke(through: corners, shake: shake)
    }
}

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, angle: CGFloat = 0) -> [CGPoint] {
    let center = CGPoint(x: x + w / 2, y: y + h / 2)
    return [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h), CGPoint(x: x, y: y)]
        .map { ($0 - center).rotated(by: angle) + center }
}

private func degrees(_ value: CGFloat) -> CGFloat { value * .pi / 180 }

private func expectClose(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(hypot(a.x - b.x, a.y - b.y) <= tolerance, "\(a) is not near \(b)", sourceLocation: sourceLocation)
}

struct ShapeRecognizerTests {
    // MARK: Lines

    @Test func aShakyNearlyHorizontalLineBecomesExactlyHorizontal() throws {
        var hand = Hand(seed: 1)
        let end = CGPoint(x: 100, y: 100).rotated(by: 0) + CGPoint(x: 200 * cos(degrees(3)), y: 200 * sin(degrees(3)))
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: [CGPoint(x: 100, y: 100), end], shake: 2)))
        #expect(shape.kind == .line)
        #expect(abs(shape.corners[1].y - shape.corners[0].y) < 0.001)  // exactly horizontal
        #expect(abs(shape.corners[1].x - shape.corners[0].x - 200) < 5)  // length kept
    }

    @Test func aSlantedLineKeepsItsAngle() throws {
        var hand = Hand(seed: 2)
        let start = CGPoint(x: 50, y: 300), end = CGPoint(x: 50 + 150 * cos(degrees(30)), y: 300 - 150 * sin(degrees(30)))
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: [start, end], shake: 1.5)))
        #expect(shape.kind == .line)
        expectClose(shape.corners[1], end, within: 4)
    }

    @Test func aNearlyVerticalLineBecomesExactlyVertical() throws {
        var hand = Hand(seed: 3)
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: [CGPoint(x: 100, y: 100), CGPoint(x: 108, y: 220)], shake: 1)))
        #expect(shape.kind == .line)
        #expect(abs(shape.corners[1].x - shape.corners[0].x) < 0.001)
    }

    // MARK: Closed shapes

    @Test func aShakyRectangleBecomesAnUprightRectangle() throws {
        var hand = Hand(seed: 4)
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: box(100, 100, 200, 120), shake: 3)))
        #expect(shape.kind == .rectangle)
        #expect(shape.angle == 0)
        expectClose(shape.corners.min(by: { $0.x + $0.y < $1.x + $1.y })!, CGPoint(x: 100, y: 100), within: 6)
        expectClose(shape.corners.max(by: { $0.x + $0.y < $1.x + $1.y })!, CGPoint(x: 300, y: 220), within: 6)
    }

    @Test func aRectangleTurnedSlightlyBecomesUpright() throws {
        var hand = Hand(seed: 5)
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: box(100, 100, 160, 100, angle: degrees(6)), shake: 2)))
        #expect(shape.kind == .rectangle)
        #expect(shape.angle == 0)
        // Upright: two corners share each x and each y.
        let xs = Set(shape.corners.map { ($0.x * 1000).rounded() }), ys = Set(shape.corners.map { ($0.y * 1000).rounded() })
        #expect(xs.count == 2 && ys.count == 2)
    }

    @Test func aRectangleTurnedFarKeepsItsAngle() throws {
        var hand = Hand(seed: 6)
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: box(100, 100, 160, 100, angle: degrees(30)), shake: 2)))
        #expect(shape.kind == .rectangle)
        #expect(abs(abs(shape.angle) - degrees(30)) < degrees(4) || abs(abs(shape.angle) - degrees(60)) < degrees(4))
    }

    @Test func aRectangleWhoseEndsDoNotQuiteMeetIsStillARectangle() throws {
        var hand = Hand(seed: 7)
        var corners = box(100, 100, 200, 120)
        corners[4] = CGPoint(x: 100, y: 130)  // stops 30 pt short of the start
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: corners, shake: 2)))
        #expect(shape.kind == .rectangle)
    }

    @Test func aShakyEllipseBecomesAnEllipse() throws {
        var hand = Hand(seed: 8)
        let shape = try #require(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 200, y: 200), rx: 100, ry: 60, shake: 3)))
        #expect(shape.kind == .ellipse)
        let box = Geometry.boundingBox(of: shape.corners)
        #expect(abs(box.width - 200) < 10 && abs(box.height - 120) < 10)
    }

    @Test func aCircleBecomesAnEllipse() throws {
        var hand = Hand(seed: 9)
        let shape = try #require(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 150, y: 150), rx: 40, ry: 40, shake: 1.5)))
        #expect(shape.kind == .ellipse)
    }

    @Test func aTurnedEllipseKeepsItsAngle() throws {
        var hand = Hand(seed: 10)
        let shape = try #require(ShapeRecognizer.recognize(
            hand.ellipse(center: CGPoint(x: 200, y: 200), rx: 100, ry: 40, angle: degrees(35), shake: 2)))
        #expect(shape.kind == .ellipse)
        #expect(abs(shape.angle) > degrees(20))
    }

    @Test func aShakyTriangleBecomesATriangle() throws {
        var hand = Hand(seed: 11)
        let corners = [CGPoint(x: 200, y: 100), CGPoint(x: 290, y: 250), CGPoint(x: 110, y: 252), CGPoint(x: 200, y: 100)]
        let shape = try #require(ShapeRecognizer.recognize(hand.stroke(through: corners, shake: 3)))
        #expect(shape.kind == .triangle)
        #expect(shape.corners.count == 3)
        // The base was 0.6 degrees off horizontal; it becomes exact.
        let bottom = shape.corners.sorted { $0.y > $1.y }
        #expect(abs(bottom[0].y - bottom[1].y) < 0.001)
    }

    @Test func manyShakyShapesAreAllRecognized() {
        // The same shapes with 20 different hands: the thresholds are not tuned to one lucky seed.
        for seed in UInt64(100)..<120 {
            var hand = Hand(seed: seed)
            #expect(ShapeRecognizer.recognize(hand.stroke(through: box(50, 50, 180, 110), shake: 3))?.kind == .rectangle, "seed \(seed)")
            #expect(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 200, y: 200), rx: 90, ry: 55, shake: 3))?.kind == .ellipse, "seed \(seed)")
            let triangle = [CGPoint(x: 100, y: 50), CGPoint(x: 180, y: 190), CGPoint(x: 20, y: 190), CGPoint(x: 100, y: 50)]
            #expect(ShapeRecognizer.recognize(hand.stroke(through: triangle, shake: 3))?.kind == .triangle, "seed \(seed)")
            #expect(ShapeRecognizer.recognize(hand.stroke(through: [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 40)], shake: 2))?.kind == .line, "seed \(seed)")
        }
    }

    // MARK: Writing is left alone

    @Test func aSmallLetterOIsNotAShape() {
        var hand = Hand(seed: 12)
        #expect(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 50, y: 50), rx: 4, ry: 5, shake: 0.5)) == nil)
    }

    @Test func aFigureEightIsNotAShape() {
        var hand = Hand(seed: 13)
        let top = hand.ellipse(center: CGPoint(x: 100, y: 80), rx: 15, ry: 15, turns: 1, shake: 1)
        let bottom = hand.ellipse(center: CGPoint(x: 100, y: 110), rx: 15, ry: 15, turns: 1, shake: 1)
            .map { CGPoint(x: 200 - $0.x, y: $0.y + 0) }  // mirrored: the pen crosses over in the middle
        #expect(ShapeRecognizer.recognize(top + bottom.reversed()) == nil)
    }

    @Test func aCursiveWordIsNotAShape() {
        // Loops along a baseline, like "ellelle".
        let points = (0...300).map { index -> CGPoint in
            let t = CGFloat(index) / 300 * 7 * 2 * .pi
            return CGPoint(x: 20 + CGFloat(index) * 0.5 + 8 * sin(t), y: 100 - 10 * (1 - cos(t)))
        }
        #expect(ShapeRecognizer.recognize(points) == nil)
    }

    @Test func aZigzagIsNotALine() {
        var hand = Hand(seed: 14)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 0), CGPoint(x: 60, y: 30), CGPoint(x: 80, y: 0)]
        #expect(ShapeRecognizer.recognize(hand.stroke(through: corners, shake: 1)) == nil)
    }

    @Test func anSCurveIsNotALine() {
        let points = (0...60).map { index -> CGPoint in
            let t = CGFloat(index) / 60
            return CGPoint(x: t * 120, y: 20 * sin(t * 2 * .pi))
        }
        #expect(ShapeRecognizer.recognize(points) == nil)
    }

    @Test func anOpenArcIsNotAShape() {
        var hand = Hand(seed: 15)
        #expect(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 100, y: 100), rx: 50, ry: 50, turns: 0.6, shake: 1)) == nil)
    }

    @Test func aScribbleBackAndForthIsNotAShape() {
        var hand = Hand(seed: 16)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 5), CGPoint(x: 0, y: 8), CGPoint(x: 100, y: 12), CGPoint(x: 2, y: 3)]
        #expect(ShapeRecognizer.recognize(hand.stroke(through: corners, shake: 1)) == nil)
    }

    @Test func aDoubleCircleIsNotAShape() {
        var hand = Hand(seed: 17)
        #expect(ShapeRecognizer.recognize(hand.ellipse(center: CGPoint(x: 100, y: 100), rx: 40, ry: 40, turns: 2, shake: 1)) == nil)
    }

    // MARK: Following the Pencil

    @Test func aLinesEndFollowsThePencil() {
        let line = SnappedShape(kind: .line, corners: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], angle: 0)
        let moved = line.following(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 80))
        #expect(moved.corners[0] == CGPoint(x: 0, y: 0))
        #expect(moved.corners[1] == CGPoint(x: 100, y: 80))
    }

    @Test func aFollowingLineStillSnapsToHorizontal() {
        let line = SnappedShape(kind: .line, corners: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], angle: 0)
        let moved = line.following(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 200, y: 4))
        #expect(abs(moved.corners[1].y) < 0.001)
    }

    @Test func aRectangleGrowsFromTheCornerThatWasHeld() {
        let rectangle = SnappedShape(kind: .rectangle, corners: Array(box(0, 0, 100, 50).dropLast()), angle: 0)
        let moved = rectangle.following(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 150, y: 100))
        let bounds = Geometry.boundingBox(of: moved.corners)
        #expect(bounds == CGRect(x: 0, y: 0, width: 150, height: 100))  // the top left corner stayed
    }

    @Test func aTurnedRectangleKeepsItsAngleWhileResized() {
        let angle = degrees(30)
        let corners = Array(box(0, 0, 100, 50, angle: angle).dropLast())
        let rectangle = SnappedShape(kind: .rectangle, corners: corners, angle: angle)
        let moved = rectangle.following(from: corners[2], to: corners[2] + CGPoint(x: 30, y: 30))
        let side = moved.corners[1] - moved.corners[0]
        #expect(abs(atan2(side.y, side.x) - angle) < 0.001)
    }

    @Test func aShapeNeverFlipsOrDisappears() {
        let rectangle = SnappedShape(kind: .rectangle, corners: Array(box(0, 0, 100, 50).dropLast()), angle: 0)
        let moved = rectangle.following(from: CGPoint(x: 100, y: 50), to: CGPoint(x: -300, y: -300))
        let bounds = Geometry.boundingBox(of: moved.corners)
        #expect(bounds.minX == 0 && bounds.minY == 0)
        #expect(bounds.width >= ShapeRecognizer.minimumFollowSize - 0.001 && bounds.height >= ShapeRecognizer.minimumFollowSize - 0.001)
    }

    @Test func theOutlineIsClosedAndHasSharpCorners() {
        let rectangle = SnappedShape(kind: .rectangle, corners: Array(box(0, 0, 100, 50).dropLast()), angle: 0)
        let piece = rectangle.outline.pieces[0]
        #expect(piece.count == 15)  // 5 points (closed), each repeated 3 times
        #expect(piece.first == piece.last)
    }
}

struct HoldDetectorTests {
    @Test func stayingStillForHalfASecondIsAHold() {
        var detector = HoldDetector()
        detector.add(CGPoint(x: 10, y: 10), at: 1.0)
        #expect(!detector.isHolding(at: 1.4))
        #expect(detector.isHolding(at: 1.5))
        #expect(detector.holdTime == 1.5)
    }

    @Test func aTremblingHandStillHolds() {
        var detector = HoldDetector()
        for step in 0...12 {
            let jitter = CGFloat(step % 3) - 1  // -1, 0, 1 points
            detector.add(CGPoint(x: 50 + jitter * 1.5, y: 50 - jitter), at: 2.0 + Double(step) * 0.05)
        }
        #expect(detector.isHolding(at: 2.6))
    }

    @Test func aSlowStrokeIsNotAHold() {
        var detector = HoldDetector()
        for step in 0...20 {  // 3 points per 0.1 s: slow, but always moving
            let time = Double(step) * 0.1
            detector.add(CGPoint(x: CGFloat(step) * 3, y: 0), at: time)
            #expect(!detector.isHolding(at: time))
        }
    }

    @Test func aShortPauseIsNotAHold() {
        var detector = HoldDetector()
        detector.add(CGPoint(x: 0, y: 0), at: 0)
        detector.add(CGPoint(x: 0, y: 1), at: 0.4)  // paused 0.4 s
        detector.add(CGPoint(x: 20, y: 0), at: 0.45)  // and moved on
        #expect(!detector.isHolding(at: 0.8))
        #expect(detector.isHolding(at: 0.96))  // only once it rests again for 0.5 s
    }
}

import PencilKit
import UIKit

struct InkTemplateTests {
    private func stroke(sizes: [CGFloat], ink: PKInkingTool.InkType = .pencil) -> PKStroke {
        let points = sizes.enumerated().map { index, size in
            PKStrokePoint(location: CGPoint(x: CGFloat(index) * 5, y: 0), timeOffset: Double(index) * 0.01,
                          size: CGSize(width: size, height: size), opacity: 0.39, force: 0.6, azimuth: 1.2, altitude: 0.9)
        }
        return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    @Test func theLookIsCopiedFromTheTypicalPointNotTheThinEnds() throws {
        let template = try #require(InkTemplate.from(stroke(sizes: [0.5, 3, 3.1, 3.2, 0.8])))
        // PencilKit stores point values with less precision than CGFloat.
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        #expect(near(template.size.width, 3))  // sorted: 0.5, 0.8, 3, 3.1, 3.2
        #expect(near(template.opacity, 0.39) && near(template.force, 0.6) && near(template.azimuth, 1.2) && near(template.altitude, 0.9))
    }

    @Test func aSnappedStrokeHasThePensInkColorAndLook() {
        let template = InkTemplate(size: CGSize(width: 4, height: 4), opacity: 0.39, force: 0.6, azimuth: 1.2, altitude: 0.9)
        let shape = SnappedShape(kind: .line, corners: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], angle: 0)
        let built = template.stroke(through: shape.outline.pieces[0], ink: PKInk(.marker, color: .red))
        #expect(built.ink.inkType == .marker)
        #expect(built.ink.color.cgColor.components?.prefix(3).map { ($0 * 100).rounded() } == [100, 0, 0])
        #expect(Array(built.path).allSatisfy { abs($0.size.width - 4) < 0.001 && abs($0.opacity - 0.39) < 0.001 && abs($0.force - 0.6) < 0.001 })
    }

    @Test func everyInkHasAFallbackLook() {
        for kind in PenKind.allCases {
            let template = InkTemplate.fallback(for: kind.inkType, width: CGFloat(kind.defaultWidth))
            #expect(template.size.width > 0 && template.opacity > 0, "\(kind)")
        }
    }

    @Test func holdToSnapIsOnByDefaultAlsoForOldSettings() throws {
        #expect(ToolSettings().holdToSnapShapes)
        let old = try JSONDecoder().decode(ToolSettings.self, from: Data("{}".utf8))
        #expect(old.holdToSnapShapes)
        var off = ToolSettings()
        off.holdToSnapShapes = false
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(off))
        #expect(!decoded.holdToSnapShapes)
    }
}

@MainActor
struct HoldGestureTests {
    @Test func theHoldGestureWatchesOnlyPencilKitsDrawingGesture() {
        let overlay = PageOverlayView(pageID: UUID())
        let hold = overlay.holdGesture
        #expect(overlay.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: overlay.canvas.drawingGestureRecognizer))
        #expect(!overlay.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
        // After an undo the page has a fresh canvas, and the old one still covers it for a moment.
        let old = overlay.canvas
        overlay.replaceCanvas()
        #expect(overlay.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: overlay.canvas.drawingGestureRecognizer))
        #expect(overlay.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: old.drawingGestureRecognizer))
    }
}

struct InkTemplateDrawableTests {
    @Test func aThinFountainPenShapeIsNeverInvisible() {
        // A copied median of 1.6 would draw nothing with the fountain pen (2 or less is invisible).
        let thin = InkTemplate(size: CGSize(width: 1.6, height: 1.6), opacity: 1, force: 0.4, azimuth: 1, altitude: 1)
        for ink: PKInkingTool.InkType in [.fountainPen, .pen, .monoline] {
            #expect(thin.drawable(with: ink, width: 2.5).size.width > 2, "\(ink.rawValue)")
        }
        // Other inks keep the copied size; a big size is never made smaller.
        #expect(thin.drawable(with: .pencil, width: 2.5).size.width == 1.6)
        let big = InkTemplate(size: CGSize(width: 9, height: 9), opacity: 1, force: 1, azimuth: 1, altitude: 1)
        #expect(big.drawable(with: .fountainPen, width: 2.5).size.width == 9)
    }
}
