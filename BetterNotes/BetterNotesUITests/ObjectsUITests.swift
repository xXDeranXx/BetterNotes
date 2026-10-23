import XCTest

/// End to end (M8): paste an image onto a page, select and delete it, undo, and type a text box.
/// Both object tests run as parts of one test, so the app launches once (see `InkUITests`).
final class ObjectsUITests: XCTestCase {
    @MainActor
    func testObjects() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skipTabRestore", "YES"]  // start in the library, not in old tabs
        app.launch()
        try pasteSelectDeleteAndTypeText(app)
        try longPressPastesImageAndTextWhereTheFingerWas(app)
    }
}

extension ObjectsUITests {
    @MainActor
    func pasteSelectDeleteAndTypeText(_ app: XCUIApplication) throws {
        showLibrary(app)
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        sleep(2)
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func shot(_ name: String) -> UIImage {
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return shot.image
        }

        // A red picture on the clipboard (the simulator shares it with the app).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let red = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        UIPasteboard.general.setData(red, forPasteboardType: "public.png")

        app.buttons["Insert image"].firstMatch.tap()
        app.buttons["Paste"].firstMatch.tap()
        // iPadOS asks once before an app reads the clipboard.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(2)
        let redCenter = redFraction(shot("pasted"))
        XCTAssertGreaterThan(redCenter, 0.02, "the pasted image is not on the page")

        // Select it and delete it from its menu.
        app.buttons["Select images and text"].firstMatch.tap()
        point(0.5, 0.5).tap()
        sleep(1)
        _ = shot("selected")
        let delete = app.menuItems["Delete"].exists ? app.menuItems["Delete"] : app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "no edit menu after tapping the image")
        delete.tap()
        sleep(1)
        XCTAssertLessThan(redFraction(shot("deleted")), 0.005, "the deleted image is still there")
        undo.tap()
        sleep(1)
        XCTAssertGreaterThan(redFraction(shot("undone")), 0.02, "undo did not bring the image back")

        // A text box: tap with the text tool, type, finish by picking another tool.
        app.buttons["Text box"].firstMatch.tap()
        sleep(1)
        _ = shot("text tool")
        point(0.3, 0.3).tap()
        sleep(1)
        _ = shot("after text tap")
        // The text view sits inside PDFView's page, which hides it from UI testing, so typeText
        // cannot find it; tap the keyboard's keys instead.
        for key in ["H", "i", "space", "M", "8"] {
            let button = key == "space" ? app.keys["space"] : app.keys[key]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
        sleep(1)
        _ = shot("typing")
        // Close the notebook while still typing: the text must be in the closing save
        // (the run script then reads the newest notebook's meta.json).
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        sleep(1)
        _ = shot("closed")
    }

    /// Holding a finger on an empty spot offers Paste there, without iPadOS asking "Allow Paste?";
    /// an image lands under the finger, text becomes a text box, and the text tool does not also
    /// place a box when the finger lifts.
    @MainActor
    func longPressPastesImageAndTextWhereTheFingerWas(_ app: XCUIApplication) throws {
        showLibrary(app)
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        app.buttons["New Notebook"].firstMatch.tap()
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func tapPasteInMenu(_ name: String) {
            let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 3), "no Paste after holding a finger: \(name)")
            _ = shot(name)
            paste.tap()
            XCTAssertFalse(springboard.buttons["Allow Paste"].waitForExistence(timeout: 2), "iPadOS asked to allow pasting")
            sleep(2)
        }

        // An image, with the select tool, held in the lower left.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let red = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        UIPasteboard.general.setData(red, forPasteboardType: "public.png")
        app.buttons["Select images and text"].firstMatch.tap()
        point(0.3, 0.65).press(forDuration: 1.0)
        tapPasteInMenu("image menu")
        let pasted = shot("image pasted")
        XCTAssertGreaterThan(redFraction(pasted, around: CGPoint(x: 0.3, y: 0.65)), 0.5, "the image is not under the finger")
        XCTAssertLessThan(redFraction(pasted, around: CGPoint(x: 0.7, y: 0.3)), 0.01, "the image is somewhere else too")

        // Text, with the text tool, held in the upper right: a text box, and no extra empty box.
        UIPasteboard.general.string = "Pasted words"
        app.buttons["Text box"].firstMatch.tap()
        sleep(1)
        point(0.7, 0.3).press(forDuration: 1.0)
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "holding placed a text box for typing")
        tapPasteInMenu("text menu")
        _ = shot("text pasted")

        // The new box is a text box: selecting it shows Edit Text.
        app.buttons["Select images and text"].firstMatch.tap()
        point(0.7, 0.3).tap()
        let edit = app.menuItems["Edit Text"].exists ? app.menuItems["Edit Text"] : app.buttons["Edit Text"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "no text box where the text was pasted")
        _ = shot("text selected")
        let font = app.menuItems["Font"].exists ? app.menuItems["Font"] : app.buttons["Font"]
        font.tap()
        sleep(1)
        _ = shot("font menu")
        let bold = app.menuItems["Bold"].exists ? app.menuItems["Bold"] : app.buttons["Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 2), "no Bold in the Font menu")
        bold.tap()
        sleep(1)
        _ = shot("bold")

        // The text tool's options: fonts, size, B and I.
        app.buttons["Text box"].firstMatch.tap()
        sleep(1)
        app.buttons["Text box"].firstMatch.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["Italic"].waitForExistence(timeout: 3), "no Italic in the text options")
        app.buttons["Noteworthy"].firstMatch.tap()
        app.buttons["Bold"].firstMatch.tap()
        sleep(1)
        _ = shot("text options")
    }

    private func shot(_ name: String) -> UIImage {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot.image
    }

    /// Share of clearly red pixels in a small square around a point (normalized coordinates).
    private func redFraction(_ image: UIImage, around center: CGPoint) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let side = CGFloat(min(cg.width, cg.height)) * 0.04
        let rect = CGRect(
            x: center.x * CGFloat(cg.width) - side / 2, y: center.y * CGFloat(cg.height) - side / 2, width: side, height: side
        ).integral
        guard let crop = cg.cropping(to: rect) else { return 0 }
        return redFraction(UIImage(cgImage: crop))
    }

    /// Share of pixels that are clearly red.
    private func redFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, total = 0
        for i in stride(from: 0, to: data.count, by: 4 * 16) {
            total += 1
            if data[i] > 200 && data[i + 1] < 60 && data[i + 2] < 60 { red += 1 }
        }
        return Double(red) / Double(max(total, 1))
    }
}
