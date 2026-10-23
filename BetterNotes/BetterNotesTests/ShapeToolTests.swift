import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Reads one pixel (red, green, blue, alpha; 0-255) of an image, from its top-left corner.
@MainActor
private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let cg = image.cgImage!
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: CGFloat(-x), y: CGFloat(-(cg.height - 1 - y)))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let p = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
}

/// Renders strokes as PencilKit draws them, on a transparent 200 x 200 point image at scale 1.
@MainActor
private func render(_ strokes: [PKStroke]) -> UIImage {
    var image = UIImage()
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        image = PKDrawing(strokes: strokes).image(from: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1)
    }
    return image
}

struct ShapeGeometryTests {
    @Test func shapesFillTheDraggedBoxInAnyDirection() {
        let rect = ShapeGeometry.path(.rectangle, from: CGPoint(x: 150, y: 120), to: CGPoint(x: 50, y: 20))
        #expect(rect == [CGPoint(x: 50, y: 20), CGPoint(x: 150, y: 20), CGPoint(x: 150, y: 120),
                         CGPoint(x: 50, y: 120), CGPoint(x: 50, y: 20)])
        let triangle = ShapeGeometry.path(.triangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 80))
        #expect(triangle == [CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 80), CGPoint(x: 0, y: 80), CGPoint(x: 50, y: 0)])
        let line = ShapeGeometry.path(.line, from: CGPoint(x: 90, y: 10), to: CGPoint(x: 10, y: 50))
        #expect(line == [CGPoint(x: 90, y: 10), CGPoint(x: 10, y: 50)])
    }

    @Test func anEllipseIsClosedAndTouchesItsBox() {
        let points = ShapeGeometry.path(.ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100))
        #expect(points.first == points.last)
        #expect(abs(points.map(\.x).min()! - 0) < 0.001 && abs(points.map(\.x).max()! - 200) < 0.001)
        #expect(abs(points.map(\.y).min()! - 0) < 0.001 && abs(points.map(\.y).max()! - 100) < 0.001)
        for point in points {  // every point lies on the ellipse
            let value = pow((point.x - 100) / 100, 2) + pow((point.y - 50) / 50, 2)
            #expect(abs(value - 1) < 0.0001)
        }
    }

    @Test func aTapDrawsNothing() {
        #expect(ShapeGeometry.outline(.rectangle, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 6),
                                      style: .solid, width: 3, filled: true) == nil)
    }

    @Test func cornersAreRepeatedSoTheyStaySharp() throws {
        let outline = try #require(ShapeGeometry.outline(
            .rectangle, from: .zero, to: CGPoint(x: 10, y: 10), style: .solid, width: 2, filled: false))
        #expect(outline.pieces.count == 1)
        #expect(outline.pieces[0].count == 15)  // 5 corners, three times each
        #expect(Array(outline.pieces[0][3..<6]) == Array(repeating: CGPoint(x: 10, y: 0), count: 3))
    }

    @Test func dashedAndDottedOutlinesAreManyPieces() throws {
        for style in [LineStyle.dashed, .dotted] {
            let outline = try #require(ShapeGeometry.outline(
                .ellipse, from: .zero, to: CGPoint(x: 200, y: 100), style: style, width: 3, filled: false))
            #expect(outline.pieces.count > 10)
        }
    }

    @Test func aLineIsNeverFilled() throws {
        let outline = try #require(ShapeGeometry.outline(
            .line, from: .zero, to: CGPoint(x: 100, y: 100), style: .solid, width: 3, filled: true))
        #expect(outline.fill == nil)
    }

    @Test func theFillStaysInsideTheShapeShrunkByHalfItsWidth() throws {
        let inset = ShapeGeometry.fillWidth / 2
        let start = CGPoint(x: 20, y: 30), end = CGPoint(x: 220, y: 180)
        for kind in [ShapeKind.rectangle, .ellipse, .triangle] {
            let fill = try #require(ShapeGeometry.fillZigzag(kind, from: start, to: end))
            let inner = try #require(ShapeGeometry.insetPolygon(kind, from: start, to: end, by: inset))
            for point in fill {
                let span = try #require(ShapeGeometry.span(of: inner, atY: point.y))
                #expect(point.x >= span.lowerBound - 0.001 && point.x <= span.upperBound + 0.001)
            }
            // Rows cover the inside from top to bottom without gaps wider than the fill.
            let ys = Array(Set(fill.map(\.y))).sorted()
            #expect(zip(ys, ys.dropFirst()).allSatisfy { $1 - $0 <= ShapeGeometry.fillRowSpacing + 0.001 })
            #expect(abs(ys.first! - inner.map(\.y).min()!) < 0.001 && abs(ys.last! - inner.map(\.y).max()!) < 0.001)
        }
    }

    @Test func anInsetTriangleKeepsTheSameDistanceFromEverySide() throws {
        let start = CGPoint.zero, end = CGPoint(x: 120, y: 90)
        let outer = Array(ShapeGeometry.path(.triangle, from: start, to: end).prefix(3))
        let inner = Array(try #require(ShapeGeometry.insetPolygon(.triangle, from: start, to: end, by: 5)).prefix(3))
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / hypot(b.x - a.x, b.y - a.y)
        }
        for index in 0..<3 {
            let a = outer[index], b = outer[(index + 1) % 3]
            // The inner side parallel to this one lies 5 points away.
            #expect(abs(distance(inner[index], a, b) - 5) < 0.001)
            #expect(abs(distance(inner[(index + 1) % 3], a, b) - 5) < 0.001)
        }
    }

    @Test func aShapeTooSmallForTheFillHasOnlyItsOutline() throws {
        let outline = try #require(ShapeGeometry.outline(
            .rectangle, from: .zero, to: CGPoint(x: 6, y: 40), style: .solid, width: 3, filled: true))
        #expect(outline.fill == nil)
        #expect(!outline.pieces.isEmpty)
    }
}

/// How PencilKit really draws the strokes (offscreen render, no screen needed).
@MainActor
struct ShapeRenderingTests {
    @Test func aRectangleHasStraightEdgesAndSharpCorners() throws {
        let outline = try #require(ShapeGeometry.outline(
            .rectangle, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150), style: .solid, width: 4, filled: false))
        let image = render(ShapeGeometry.strokes(for: outline, color: .black, width: 4))
        // Without repeated corners the edges bowed inward and the middle of an edge was faint (121).
        for (x, y) in [(100, 49), (100, 50), (150, 100), (100, 150), (50, 100), (50, 50), (150, 150)] {
            #expect(pixel(image, x, y).a > 200, "edge pixel \(x), \(y)")
        }
        #expect(pixel(image, 100, 100).a == 0)  // not filled
        #expect(pixel(image, 56, 56).a == 0)  // the corner is not rounded inward
    }

    @Test func dashesAndDotsShowAsSeparateMarksWithPenInk() throws {
        for (style, minimumMarks) in [(LineStyle.dashed, 4), (.dotted, 10)] {
            let outline = try #require(ShapeGeometry.outline(
                .rectangle, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 150), style: style, width: 3, filled: false))
            let image = render(ShapeGeometry.strokes(for: outline, color: .black, width: 3))
            // Walk along the top edge and count where ink starts again after a gap.
            var marks = 0, wasInk = false, gapPixels = 0
            for x in 25...175 {
                let isInk = pixel(image, x, 50).a > 128
                if isInk && !wasInk { marks += 1 }
                if !isInk { gapPixels += 1 }
                wasInk = isInk
            }
            #expect(marks >= minimumMarks, "\(style): \(marks) marks")
            #expect(gapPixels > 30, "\(style): gaps of \(gapPixels) px")
        }
    }

    @Test func theFillIsAnEvenLightTintAndStaysInsideTheOutline() throws {
        let outline = try #require(ShapeGeometry.outline(
            .ellipse, from: CGPoint(x: 20, y: 40), to: CGPoint(x: 180, y: 160), style: .dashed, width: 3, filled: true))
        let strokes = ShapeGeometry.strokes(for: outline, color: .blue, width: 3)
        #expect(strokes.first?.ink.color.cgColor.alpha ?? 1 < 0.5)  // the fill comes first, under the outline
        let image = render(strokes)
        // The one zigzag stroke overlaps itself, but PencilKit draws a stroke as one shape:
        // the tint is the same between rows and on them (no darker bands).
        let samples = [(100, 100), (100, 103), (60, 100), (140, 90), (100, 60), (100, 140)].map { pixel(image, $0.0, $0.1) }
        let alphas = samples.map(\.a)
        #expect(alphas.allSatisfy { $0 > 40 && $0 < 90 }, "tint \(alphas)")
        #expect(alphas.max()! - alphas.min()! <= 4, "tint \(alphas)")
        // Outside the ellipse (a little beyond its line) there is no paint.
        for (x, y) in [(100, 34), (100, 166), (14, 100), (186, 100), (30, 50)] {
            #expect(pixel(image, x, y).a == 0, "outside \(x), \(y)")
        }
    }
}

struct ShapeSettingsTests {
    @Test func shapeChoicesSurviveARestart() throws {
        var settings = ToolSettings()
        settings.selected = .shape
        settings.shape.kind = .triangle
        settings.shape.lineStyle = .dotted
        settings.shape.isFilled = true
        settings.setShapeColor("#e5484d")
        settings.setShapeWidth(6)
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.shape.colorHex == "#E5484D")
    }

    @Test func settingsFromBeforeTheShapeToolGetDefaults() throws {
        let old = #"{"version":1,"selected":{"lasso":{}},"eraserWidth":30}"#
        let settings = try JSONDecoder().decode(ToolSettings.self, from: Data(old.utf8))
        #expect(settings.shape == ShapeSetting())
        #expect(settings.selected == .lasso)
        #expect(settings.eraserWidth == 30)
    }

    @Test func badShapeValuesAreRepaired() throws {
        let stored = #"{"shape":{"kind":"hexagon","colorHex":"nope","width":500,"isFilled":true}}"#
        let shape = try JSONDecoder().decode(ToolSettings.self, from: Data(stored.utf8)).shape
        #expect(shape.kind == .rectangle)
        #expect(shape.colorHex == "#000000")
        #expect(shape.width == ShapeSetting.widthRange.upperBound)
        #expect(shape.isFilled)
    }

    @Test func theShapeToolKeepsItsOwnColorApartFromThePens() {
        var settings = ToolSettings()
        settings.setShapeColor("#30A46C")
        #expect(settings.setting(for: .pen).colorHex == "#000000")
        settings.selected = .shape
        let tool = settings.makeTool() as? PKInkingTool
        #expect(tool.map { HexColor.hex(of: $0.color) } == "#30A46C")
    }
}

/// The shape tool in the editor, with real canvases (they work without a window).
@MainActor
struct ShapeToolEditorTests {
    private func makeEditor() throws -> (TempFolder, Notebook, EditorCoordinator, PageOverlayView) {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        let coordinator = EditorCoordinator(notebook: notebook)
        let overlay = PageOverlayView(pageID: notebook.pages[0].id)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        overlay.canvas.delegate = coordinator
        coordinator.overlayDidAppear(overlay)
        return (folder, notebook, coordinator, overlay)
    }

    private func shapeSettings() -> ToolSettings {
        var settings = ToolSettings()
        settings.selected = .shape
        settings.shape.isFilled = true
        settings.shape.lineStyle = .dashed
        return settings
    }

    @Test func theShapeToolSwitchesPencilKitsDrawingOffAndBackOn() throws {
        let (_, _, coordinator, overlay) = try makeEditor()
        #expect(overlay.canvas.drawingGestureRecognizer.isEnabled && !overlay.shapeGesture.isEnabled)

        coordinator.apply(settings: shapeSettings(), isRulerActive: false)
        #expect(!overlay.canvas.drawingGestureRecognizer.isEnabled && overlay.shapeGesture.isEnabled)

        coordinator.apply(settings: ToolSettings(), isRulerActive: false)
        #expect(overlay.canvas.drawingGestureRecognizer.isEnabled && !overlay.shapeGesture.isEnabled)
    }

    @Test func aShapeIsOneUndoStepAndTheCanvasShowsIt() throws {
        let (_, notebook, coordinator, overlay) = try makeEditor()
        let settings = shapeSettings()
        coordinator.apply(settings: settings, isRulerActive: false)
        let pageID = notebook.pages[0].id

        coordinator.addShape(settings.shape, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), on: overlay)

        let strokes = notebook.drawing(for: pageID).strokes
        #expect(strokes.count > 10)  // a fill and many dashes
        #expect(overlay.canvas.drawing.strokes.count == strokes.count)
        #expect(notebook.undoManager.undoActionName == "Shape")
        notebook.undoManager.undo()
        #expect(notebook.drawing(for: pageID).strokes.isEmpty)
        #expect(!notebook.undoManager.canUndo)  // the whole shape was one step
    }

    @Test func afterAnUndoTheFreshCanvasStillDoesNotDrawWhileShapesAreOn() throws {
        let (_, notebook, coordinator, overlay) = try makeEditor()
        let settings = shapeSettings()
        coordinator.apply(settings: settings, isRulerActive: false)
        coordinator.addShape(settings.shape, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), on: overlay)
        let before = overlay.canvas

        notebook.undoManager.undo()

        #expect(overlay.canvas !== before)
        #expect(!overlay.canvas.drawingGestureRecognizer.isEnabled)
        #expect(overlay.shapeGesture.isEnabled)
    }

    @Test func thePreviewStaysUntilTheOldCanvasIsGone() throws {
        let (_, _, coordinator, overlay) = try makeEditor()
        let settings = shapeSettings()
        coordinator.apply(settings: settings, isRulerActive: false)
        let outline = ShapeGeometry.outline(.rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250),
                                            style: .solid, width: 3, filled: false)
        overlay.showShapePreview(outline, color: .black, width: 3)

        coordinator.addShape(settings.shape, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), on: overlay)

        // The old canvas without the shape still covers the page, so the preview must too.
        #expect(overlay.retiredCanvas != nil)
        #expect(overlay.isShowingShapePreview)
        overlay.retireOldCanvas()
        #expect(!overlay.isShowingShapePreview)
    }

    @Test func thePreviewIsAsSharpAsTheInkWhenZoomed() throws {
        let (_, _, coordinator, overlay) = try makeEditor()
        coordinator.zoomDidChange(to: 3)
        overlay.layoutIfNeeded()
        #expect(overlay.renderScale == 3)
        #expect(overlay.shapePreviewScale >= 3 * 2)  // at least 2x screen pixels per point, times the zoom
    }

    @Test func theSystemToolPickerNeverDrawsShapes() throws {
        let (_, _, coordinator, overlay) = try makeEditor()
        var settings = shapeSettings()
        settings.usesSystemToolPicker = true
        coordinator.apply(settings: settings, isRulerActive: false)
        #expect(overlay.canvas.drawingGestureRecognizer.isEnabled && !overlay.shapeGesture.isEnabled)
    }
}
