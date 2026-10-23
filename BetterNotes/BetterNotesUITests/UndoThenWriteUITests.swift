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
        app.buttons["Create"].firstMatch.tap()
        let undo = app.navigationBars.firstMatch.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        sleep(2)

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
