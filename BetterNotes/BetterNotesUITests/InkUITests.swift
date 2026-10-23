import XCTest

/// End to end, with the real `PDFView` and `PKCanvasView`: an undone stroke must stay gone when
/// the next stroke is drawn. Unit tests with a canvas that is not on screen could not show this
/// bug (PencilKit kept its own copy of the strokes after `drawing` was assigned).
/// The ink, shape and tab tests run as parts of one test, so the app launches once instead of
/// three times (the developer asked for shorter test runs, 2026-10-23). Each part starts in
/// the library with a new notebook; tabs from earlier parts stay open.
final class InkUITests: XCTestCase {
    @MainActor
    func testInkShapesAndTabs() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skipTabRestore", "YES"]  // start in the library, not in old tabs
        app.launch()
        try undoneStrokeStaysGone(app)
        try shapeIsDrawnUndoneAndKept(app)
        try whiteboardDrawsAndUndoes(app)
        try tabsKeepInkUndoAndTypingAndComeBackAfterRelaunch(app)  // last: it kills the app
    }
}

/// Goes back to the library (from an editor) so the next part can make its notebook.
@MainActor
func showLibrary(_ app: XCUIApplication) {
    if !app.buttons["Add"].exists, app.buttons["Library"].firstMatch.exists {
        app.buttons["Library"].firstMatch.tap()
    }
}

extension InkUITests {
    @MainActor
    func undoneStrokeStaysGone(_ app: XCUIApplication) throws {
        showLibrary(app)
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))  // the sheet can be slow in the simulator
        create.tap()
        let undo = app.buttons["Undo"].firstMatch
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

/// End to end on a whiteboard (board mode: the canvas is its own scroll view): ink lands where it
/// is drawn, and an undone stroke stays gone when the next one is drawn (the canvas swap).
extension InkUITests {
    @MainActor
    func whiteboardDrawsAndUndoes(_ app: XCUIApplication) throws {
        showLibrary(app)
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Whiteboard"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Lasso"].firstMatch.tap()
        app.buttons["Pen"].firstMatch.tap()
        let window = app.windows.firstMatch
        func stroke(y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: y))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: y)))
            sleep(1)
        }
        stroke(y: 0.4)
        stroke(y: 0.5)
        undo.tap()
        sleep(1)
        stroke(y: 0.6)
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "whiteboard"
        attachment.lifetime = .keepAlways
        add(attachment)
        let pixels = try XCTUnwrap(Pixels(shot.image))
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.4), "whiteboard: stroke A is missing")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.5), "whiteboard: the undone stroke came back")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.6), "whiteboard: stroke C is missing")

        // A finger held on an empty spot offers our Paste, not PencilKit's "Select All / Insert
        // Space" (seen on the iPad). The simulator shares its clipboard with the test.
        UIPasteboard.general.string = "Pasted on the board"
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75)).press(forDuration: 1.2)
        XCTAssertTrue(app.menuItems["Paste"].waitForExistence(timeout: 3), "whiteboard: no Paste after holding a finger")
        XCTAssertFalse(app.menuItems["Insert Space"].exists, "whiteboard: PencilKit's menu came instead")
        app.menuItems["Paste"].tap()
        sleep(1)
    }
}

/// End to end: a shape drawn with the shape tool lands on the page (the drag does not scroll),
/// is one undo step, the canvas does not draw freehand ink after an undo while shapes are on,
/// and the shape survives the next pen stroke.
extension InkUITests {
    @MainActor
    func shapeIsDrawnUndoneAndKept(_ app: XCUIApplication) throws {
        showLibrary(app)
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))  // the sheet can be slow in the simulator
        create.tap()
        let undo = app.buttons["Undo"].firstMatch
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

        // Write first: PencilKit's stale copy of the strokes only shows on a canvas written on.
        app.buttons["Lasso"].firstMatch.tap()  // tapping a selected tool would open its options
        app.buttons["Pen"].firstMatch.tap()
        point(0.45, 0.55).press(forDuration: 0.1, thenDragTo: point(0.75, 0.55))
        sleep(1)
        app.buttons["Shapes"].firstMatch.tap()  // a rectangle, solid, unless a run changed the shape options
        dragRectangle()
        var pixels = try shot("shape")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "top edge missing (did the drag scroll?)")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.45), "bottom edge missing")
        XCTAssertFalse(pixels.hasDarkLine(atX: 0.6, nearY: 0.40), "freehand ink inside the rectangle")

        // A stroke on the same canvas right after the shape must keep it (no fresh canvas for shapes).
        app.buttons["Lasso"].firstMatch.tap()
        app.buttons["Pen"].firstMatch.tap()
        point(0.45, 0.62).press(forDuration: 0.1, thenDragTo: point(0.75, 0.62))
        sleep(1)
        pixels = try shot("stroke after shape")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "a stroke right after the shape dropped it")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.62), "the stroke after the shape is missing")
        undo.tap()  // the stroke
        sleep(1)
        app.buttons["Lasso"].firstMatch.tap()
        app.buttons["Shapes"].firstMatch.tap()

        undo.tap()  // the shape
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
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.55), "the first pen stroke is missing")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.35), "the next stroke dropped the shape")
        XCTAssertTrue(pixels.hasDarkLine(atX: 0.6, nearY: 0.45), "the next stroke dropped the shape")
    }
}

/// End to end for tabs (tabs step 6): two notebooks as tabs, ink in each, switching keeps the
/// ink and the first tab's undo history, typing is kept when switching away in the middle of
/// it, and the tabs come back after the app was killed and launched again.
extension InkUITests {
    @MainActor
    func tabsKeepInkUndoAndTypingAndComeBackAfterRelaunch(_ app: XCUIApplication) throws {
        showLibrary(app)
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func stroke(y: CGFloat) {
            point(0.45, y).press(forDuration: 0.1, thenDragTo: point(0.75, y))
            sleep(1)
        }
        func pixels(_ name: String) throws -> Pixels {
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return try XCTUnwrap(Pixels(shot.image))
        }
        func newNotebook() {
            XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
            app.buttons["Add"].tap()
            app.buttons["New Notebook"].firstMatch.tap()
            let create = app.buttons["Create"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 10))
            create.tap()
            XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 10))
            sleep(2)
        }
        let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab:'"))
        let before = tabs.count  // tabs of the earlier parts stay open

        // Notebook 1: a stroke at 0.4, then a text box that is still being typed in.
        newNotebook()
        app.buttons["Lasso"].firstMatch.tap()  // tool settings are remembered: reach exactly the pen
        app.buttons["Pen"].firstMatch.tap()
        stroke(y: 0.4)
        app.buttons["Text box"].firstMatch.tap()
        sleep(1)
        point(0.3, 0.6).tap()
        sleep(1)
        for key in ["H", "H", "H"] {
            if app.keys[key].waitForExistence(timeout: 2) { app.keys[key].tap() }
        }
        sleep(1)

        // Notebook 2 in a new tab (from the library), with a stroke at 0.5.
        app.buttons["Library"].firstMatch.tap()
        newNotebook()
        app.buttons["Lasso"].firstMatch.tap()
        app.buttons["Pen"].firstMatch.tap()
        stroke(y: 0.5)
        XCTAssertEqual(tabs.count, before + 2)

        // Back to notebook 1: its ink and the typed text are there, notebook 2's ink is not.
        tabs.element(boundBy: before).tap()
        sleep(2)
        var page = try pixels("first tab again")
        XCTAssertTrue(page.hasDarkLine(atX: 0.6, nearY: 0.4), "the first tab's stroke is missing")
        XCTAssertFalse(page.hasDarkLine(atX: 0.6, nearY: 0.5), "the second tab's stroke shows in the first")
        XCTAssertTrue(page.hasDarkPixel(fromX: 0.3, toX: 0.36, nearY: 0.6), "the text typed before switching is gone")

        // Its undo history survived the switch: undo takes back the text box, then the stroke.
        let undo = app.buttons["Undo"].firstMatch
        undo.tap()
        sleep(1)
        undo.tap()
        sleep(1)
        page = try pixels("undone")
        XCTAssertFalse(page.hasDarkLine(atX: 0.6, nearY: 0.4), "undo after switching tabs did nothing")
        app.buttons["Redo"].firstMatch.tap()
        sleep(1)
        app.buttons["Redo"].firstMatch.tap()
        sleep(3)  // autosave

        // Killed and launched again (this time restoring): both tabs, the first one shown, its ink there.
        app.terminate()
        let again = XCUIApplication()
        again.launch()
        let restored = again.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab:'"))
        XCTAssertTrue(again.buttons["Undo"].firstMatch.waitForExistence(timeout: 10), "the shown tab was not restored")
        sleep(2)
        XCTAssertEqual(restored.count, before + 2)
        page = try pixels("after relaunch")
        XCTAssertTrue(page.hasDarkLine(atX: 0.6, nearY: 0.4), "the restored tab lost its stroke")
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

    /// A dark pixel anywhere between x and toX (fractions of the screen), near y.
    func hasDarkPixel(fromX x: CGFloat, toX: CGFloat, nearY y: CGFloat) -> Bool {
        stride(from: x, through: toX, by: 1 / CGFloat(width)).contains { hasDarkLine(atX: $0, nearY: y) }
    }
}
