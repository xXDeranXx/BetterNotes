import XCTest

/// End to end, with the real `PDFView` and `PKCanvasView`: an undone stroke must stay gone when
/// the next stroke is drawn. Unit tests with a canvas that is not on screen could not show this
/// bug (PencilKit kept its own copy of the strokes after `drawing` was assigned).
final class UndoThenWriteUITests: XCTestCase {
    @MainActor
    func testAnUndoneStrokeStaysGoneAfterTheNextStroke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))  // the sheet can be slow in the simulator
        create.tap()
        let undo = app.navigationBars.firstMatch.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        sleep(2)
        // Tool settings are remembered between launches. Tapping a selected tool opens its options,
        // so go through the lasso (it has none) to select exactly the pen.
        app.buttons["Lasso"].firstMatch.tap()
        app.buttons["Pen"].firstMatch.tap()

        let window = app.windows.firstMatch
        func stroke(y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: y))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: y)))
            sleep(1)
        }
        stroke(y: 0.4)  // A
        stroke(y: 0.5)  // B
        undo.tap()      // B goes
        sleep(1)
        stroke(y: 0.6)  // C
        sleep(1)

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        let pixels = try XCTUnwrap(Pixels(shot.image))
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.4), "stroke A is missing")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.5), "the undone stroke B came back")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.6), "stroke C is missing")
    }
}

/// End to end: a shape drawn with the shape tool lands on the page (the drag does not scroll),
/// is one undo step, the canvas does not draw freehand ink after an undo while shapes are on,
/// and the shape survives the next pen stroke.
final class ShapeToolUITests: XCTestCase {
    @MainActor
    func testAShapeIsDrawnUndoneAndKeptByTheNextStroke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))  // the sheet can be slow in the simulator
        create.tap()
        let undo = app.navigationBars.firstMatch.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        sleep(2)
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func shot(_ name: String) throws -> Pixels {
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return try XCTUnwrap(Pixels(shot.image))
        }
        func dragRectangle() {
            point(0.45, 0.35).press(forDuration: 0.1, thenDragTo: point(0.75, 0.45))
            sleep(1)
        }

        app.buttons["Lasso"].firstMatch.tap()  // tapping a selected tool would open its options
        app.buttons["Shapes"].firstMatch.tap()  // a rectangle, solid, unless a run changed the shape options
        dragRectangle()
        var pixels = try shot("shape")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "top edge missing (did the drag scroll?)")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.45), "bottom edge missing")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.40), "freehand ink inside the rectangle")

        undo.tap()
        sleep(1)
        pixels = try shot("undone")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "the undone shape is still there")

        dragRectangle()  // on the fresh canvas after the undo
        pixels = try shot("again")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "second shape missing")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.40), "the canvas drew freehand after the undo")

        app.buttons["Pen"].firstMatch.tap()
        point(0.45, 0.6).press(forDuration: 0.1, thenDragTo: point(0.75, 0.6))
        sleep(2)
        pixels = try shot("after stroke")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.6), "pen stroke missing")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "the next stroke dropped the shape")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.45), "the next stroke dropped the shape")
    }
}

/// Reads a screenshot's pixels.
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    /// A dark pixel within a few points of (x, y), given as fractions of the screen.
    func hasDarkLine(atX x: CGFloat, nearY y: CGFloat) -> Bool {
        let px = Int(x * CGFloat(width)), py = Int(y * CGFloat(height))
        for row in max(0, py - 12)...min(height - 1, py + 12) {
            let i = (row * width + px) * 4
            if bytes[i] < 80 && bytes[i + 1] < 80 && bytes[i + 2] < 80 { return true }
        }
        return false
    }
}
