import Foundation
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Text box fonts, bold and italic (M8 polish): file format, layout, typing, menu.
struct TextStyleFormatTests {
    private func roundTrip(_ object: PageObject) throws -> PageObject {
        try JSONDecoder().decode(PageObject.self, from: JSONEncoder().encode(object))
    }

    @Test func fontAndStylesRoundTripThroughJSON() throws {
        let text = TextObject(
            text: "Bold and italic", fontSize: 18, colorHex: "#112233", font: .georgia,
            styles: [TextStyleRun(start: 0, length: 4, bold: true, italic: false), TextStyleRun(start: 9, length: 6, bold: false, italic: true)])
        let object = PageObject(frame: CGRect(x: 1, y: 2, width: 200, height: 40), content: .text(text))
        #expect(try roundTrip(object) == object)

        let json = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        #expect(json.contains(#""font":"georgia""#))
        #expect(json.contains(#""text":"Bold and italic""#))  // the text stays a plain, searchable string
    }

    @Test func aVersion2TextBoxReadsAsPlainSystemText() throws {
        let json = ##"{"id":"6F1C2B6A-0000-4000-8000-000000000001","x":0,"y":0,"width":100,"height":20,"type":"text","text":"Old","fontSize":16,"colorHex":"#000000"}"##
        let object = try JSONDecoder().decode(PageObject.self, from: Data(json.utf8))
        guard case .text(let text) = object.content else { Issue.record("not text"); return }
        #expect(text.font == .system && text.styles.isEmpty)
    }

    @Test func anUnknownFontReadsAsSystemAndBadStylesAreRepaired() throws {
        let json = ##"""
            {"id":"6F1C2B6A-0000-4000-8000-000000000002","x":0,"y":0,"width":100,"height":20,"type":"text",
             "text":"abcdef","fontSize":16,"colorHex":"#000000","font":"comic-sans-from-the-future",
             "styles":[{"start":4,"length":50,"bold":true,"italic":false},{"start":0,"length":2,"bold":true,"italic":false},
                       {"start":1,"length":2,"bold":true,"italic":false},{"start":-3,"length":1,"bold":false,"italic":true}]}
            """##
        let object = try JSONDecoder().decode(PageObject.self, from: Data(json.utf8))
        guard case .text(let text) = object.content else { Issue.record("not text"); return }
        #expect(text.font == .system)
        // Clamped to the 6 characters, overlaps merged, sorted.
        #expect(text.styles == [
            TextStyleRun(start: 0, length: 3, bold: true, italic: false), TextStyleRun(start: 4, length: 2, bold: true, italic: false),
        ])
    }

    @Test func stylesCountInUTF16LikeNSString() {
        var text = TextObject(text: "😀 hi", fontSize: 16, colorHex: "#000000")
        #expect(text.utf16Length == 5)  // the emoji is 2 units
        text.set(.bold, everywhere: true)
        #expect(text.styles == [TextStyleRun(start: 0, length: 5, bold: true, italic: false)])
        #expect(TextBoxLayout.styles(from: TextBoxLayout.attributedString(for: text)) == text.styles)
    }

    @Test func wholeBoxBoldAndItalicKeepEachOther() {
        var text = TextObject(
            text: "one two", fontSize: 16, colorHex: "#000000",
            styles: [TextStyleRun(start: 0, length: 3, bold: false, italic: true)])
        #expect(!text.isEverywhere(.bold))
        text.set(.bold, everywhere: true)
        #expect(text.isEverywhere(.bold) && !text.isEverywhere(.italic))
        #expect(text.styles == [
            TextStyleRun(start: 0, length: 3, bold: true, italic: true), TextStyleRun(start: 3, length: 4, bold: true, italic: false),
        ])
        text.set(.bold, everywhere: false)
        #expect(text.styles == [TextStyleRun(start: 0, length: 3, bold: false, italic: true)])
    }
}

@MainActor
struct FormatVersion3Tests {
    @Test func aVersion2NotebookIsKeptAsMetaV2OnTheFirstWrite() throws {
        let folder = try TempFolder()
        let package = try makeNotebook(in: folder.url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: package.metaURL)) as! [String: Any]
        json["formatVersion"] = 2
        let original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: package.metaURL)

        var meta = try package.readMeta()
        #expect(meta.formatVersion == 2)
        meta.title = "Renamed"
        try package.writeMeta(meta)

        #expect(try Data(contentsOf: package.url.appending(path: "meta.v2.json")) == original)
        #expect(try package.readMeta().formatVersion == 3)
    }
}

struct TextFontTests {
    @Test(arguments: TextFont.allCases)
    func everyFamilyHasPlainBoldAndItalicFaces(family: TextFont) {
        let plain = TextBoxLayout.font(family, size: 20)
        let bold = TextBoxLayout.font(family, size: 20, bold: true)
        let italic = TextBoxLayout.font(family, size: 20, italic: true)
        let both = TextBoxLayout.font(family, size: 20, bold: true, italic: true)
        #expect(plain.pointSize == 20 && both.pointSize == 20)
        #expect(!plain.fontDescriptor.symbolicTraits.contains(.traitBold))
        // Every family on the list has a bold face.
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(both.fontDescriptor.symbolicTraits.contains(.traitBold))
        // Italic where the family has one; otherwise the plain face (no crash, no other family).
        if italic.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            #expect(both.fontDescriptor.symbolicTraits.contains(.traitItalic))
        } else {
            #expect(italic.familyName == plain.familyName)
        }
    }

    @Test func familiesThatShouldHaveItalicDo() {
        for family in [TextFont.system, .serif, .monospaced, .georgia] {
            let italic = TextBoxLayout.font(family, size: 16, italic: true)
            #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic), "\(family)")
        }
    }

    @Test func theFamiliesLookDifferent() {
        let names = Set(TextFont.allCases.map { TextBoxLayout.font($0, size: 16).fontName })
        #expect(names.count == TextFont.allCases.count)
    }

    @Test func boldTextIsWiderSoItCanWrapIntoMoreLines() {
        var text = TextObject(text: String(repeating: "Wide words wrap here ", count: 8), fontSize: 16, colorHex: "#000000")
        let plain = TextBoxLayout.height(of: text, width: 200)
        text.set(.bold, everywhere: true)
        #expect(TextBoxLayout.height(of: text, width: 200) >= plain)
        text.fontSize = 32
        #expect(TextBoxLayout.height(of: text, width: 200) > plain)
    }

    @Test func pastedTextIsAsWideAsItsLongestLineWithinLimits() {
        let short = TextObject(text: "Hi", fontSize: 16, colorHex: "#000000")
        let long = TextObject(text: String(repeating: "long ", count: 100), fontSize: 16, colorHex: "#000000")
        #expect(TextBoxLayout.pastedWidth(of: short, pageWidth: 595) < 60)
        #expect(TextBoxLayout.pastedWidth(of: short, pageWidth: 595) >= TextBoxLayout.minimumWidth)
        #expect(TextBoxLayout.pastedWidth(of: long, pageWidth: 595) == TextBoxLayout.maximumPastedWidth)
        #expect(TextBoxLayout.pastedWidth(of: long, pageWidth: 200) == 200)
    }
}

@MainActor
struct TextStyleEditingTests {
    private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let coordinator: EditorCoordinator
        let overlay: PageOverlayView
        let page: UUID
    }

    private func makeSetup(_ change: (inout ToolSettings) -> Void = { _ in }) throws -> Setup {
        let folder = try TempFolder()
        let notebook = try Notebook.open(try makeNotebook(in: folder.url))
        notebook.autosaveDelay = .seconds(60)
        let coordinator = EditorCoordinator(notebook: notebook)
        let page = notebook.pages[0].id
        let overlay = PageOverlayView(pageID: page)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        overlay.canvas.delegate = coordinator
        coordinator.overlayDidAppear(overlay)
        var settings = ToolSettings()
        settings.selected = .text
        change(&settings)
        coordinator.apply(settings: settings, isRulerActive: false)
        return Setup(folder: folder, notebook: notebook, coordinator: coordinator, overlay: overlay, page: page)
    }

    private func editor(_ setup: Setup) throws -> TextBoxEditorView {
        try #require(setup.coordinator.editingTextView as? TextBoxEditorView)
    }

    private func onlyText(_ setup: Setup) throws -> TextObject {
        let objects = setup.notebook.objects(on: setup.page)
        try #require(objects.count == 1)
        guard case .text(let text) = objects[0].content else { throw CancellationError() }
        return text
    }

    @Test func boldingSelectedWordsIsKeptWhenTypingEnds() throws {
        let setup = try makeSetup { $0.textFont = .serif }
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 100), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        let view = try editor(setup)
        view.insertText("make this bold")
        view.selectedRange = NSRange(location: 10, length: 4)
        view.toggleBoldface(nil)  // what Cmd+B and the edit menu's Bold do
        view.selectedRange = NSRange(location: 0, length: 4)
        view.toggleItalics(nil)
        setup.coordinator.endTextEditing()

        let text = try onlyText(setup)
        #expect(text.text == "make this bold" && text.font == .serif)
        #expect(text.styles == [
            TextStyleRun(start: 0, length: 4, bold: false, italic: true), TextStyleRun(start: 10, length: 4, bold: true, italic: false),
        ])
    }

    @Test func underlineIsOff() throws {
        let setup = try makeSetup()
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 100), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        let view = try editor(setup)
        view.insertText("abc")
        view.selectedRange = NSRange(location: 0, length: 3)
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.toggleUnderline(_:)), withSender: nil))
        view.toggleUnderline(nil)
        #expect(view.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func aNewBoxStartsInTheToolbarsBoldAndItalic() throws {
        let setup = try makeSetup {
            $0.textFont = .georgia
            $0.textBold = true
            $0.textItalic = true
        }
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 100), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        try editor(setup).insertText("Title")
        setup.coordinator.endTextEditing()
        let text = try onlyText(setup)
        #expect(text.font == .georgia)
        #expect(text.styles == [TextStyleRun(start: 0, length: 5, bold: true, italic: true)])
    }

    @Test func pastedRichTextKeepsOnlyBoldAndItalic() throws {
        let setup = try makeSetup()
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 100), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        let view = try editor(setup)
        // What a rich paste could leave behind: another font, size, color and a picture.
        let foreign = NSMutableAttributedString(
            string: "Big red", attributes: [.font: UIFont(name: "Courier-Bold", size: 40)!, .foregroundColor: UIColor.red])
        foreign.append(NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "star")!)))
        foreign.append(NSAttributedString(string: " plain", attributes: [.font: UIFont.systemFont(ofSize: 9)]))
        view.attributedText = foreign
        setup.coordinator.endTextEditing()

        let text = try onlyText(setup)
        #expect(text.text == "Big red plain")  // the picture is gone
        #expect(text.font == .system && text.fontSize == TextObject.defaultFontSize && text.colorHex == "#000000")
        #expect(text.styles == [TextStyleRun(start: 0, length: 7, bold: true, italic: false)])
    }

    @Test func changingTheFontOrSizeKeepsBoldWords() throws {
        let setup = try makeSetup { $0.selected = .select }
        let text = TextObject(
            text: "Some bold words", fontSize: 16, colorHex: "#000000",
            styles: [TextStyleRun(start: 5, length: 4, bold: true, italic: false)])
        let object = PageObject(frame: CGRect(x: 10, y: 10, width: 200, height: 30), content: .text(text))
        setup.notebook.addObject(object, to: setup.page, actionName: "Add")
        setup.coordinator.changeText(of: object, on: setup.page, actionName: "Font") { $0.font = .noteworthy }
        let changed = try onlyText(setup)
        #expect(changed.font == .noteworthy && changed.styles == text.styles)
        #expect(setup.notebook.undoManager.undoActionName == "Font")
    }

    @Test func pastedTextIsCentredOnThePointAndStaysOnThePage() throws {
        let setup = try makeSetup {
            $0.textFont = .monospaced
            $0.textBold = true
            $0.textFontSize = 20
        }
        let text = setup.coordinator.newText("Pasted words")
        #expect(text.font == .monospaced && text.fontSize == 20 && text.isEverywhere(.bold))

        setup.coordinator.pasteText(text, width: nil, on: setup.page, at: CGPoint(x: 300, y: 400), pageSize: setup.overlay.bounds.size)
        let frame = setup.notebook.objects(on: setup.page)[0].frame
        #expect(abs(frame.midX - 300) < 1 && abs(frame.midY - 400) < 1)
        #expect(setup.notebook.undoManager.undoActionName == "Paste")

        // Near the corner it is pushed back onto the page.
        setup.coordinator.pasteText(text, width: 300, on: setup.page, at: CGPoint(x: 590, y: 840), pageSize: setup.overlay.bounds.size)
        let corner = setup.notebook.objects(on: setup.page)[1].frame
        #expect(corner.maxX <= 595 && corner.maxY <= 842 && corner.width == 300)
    }

    @Test func aCopiedTextBoxPastesWithItsStyleAndWidth() throws {
        let text = TextObject(
            text: "Copied", fontSize: 24, colorHex: "#E5484D", font: .rounded,
            styles: [TextStyleRun(start: 0, length: 6, bold: true, italic: false)])
        PageClipboard.copy(text, width: 180)
        #expect(UIPasteboard.general.string == "Copied")  // other apps get the plain text
        #expect(PageClipboard.hasContent)
        let copied = try #require(PageClipboard.copiedTextBox())
        #expect(copied.text == text && copied.width == 180)
    }

    @Test func thePasteTargetIsUsedOnce() throws {
        let setup = try makeSetup()
        setup.coordinator.pasteTarget = PasteTarget(pageID: setup.page, point: CGPoint(x: 5, y: 6))
        #expect(setup.coordinator.takePasteTarget()?.point == CGPoint(x: 5, y: 6))
        #expect(setup.coordinator.takePasteTarget() == nil)
    }

    @Test func theLongPressWorksWithEveryToolButFingerDrawing() throws {
        let select = try makeSetup { $0.selected = .select }
        #expect(select.overlay.objectLongPress.isEnabled)  // for Paste on an empty spot
        let fingers = try makeSetup {
            $0.selected = .pen(.pen)
            $0.allowsFingerDrawing = true
        }
        #expect(!fingers.overlay.objectLongPress.isEnabled)
    }
}
