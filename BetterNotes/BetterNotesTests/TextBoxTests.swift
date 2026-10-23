import Foundation
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

@MainActor
struct TextBoxTests {
    private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let coordinator: EditorCoordinator
        let overlay: PageOverlayView
        let page: UUID
    }

    private func makeSetup(tool: ToolChoice = .text) throws -> Setup {
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
        settings.selected = tool
        settings.textFontSize = 20
        settings.textColorHex = "#1E5BFF"
        coordinator.apply(settings: settings, isRulerActive: false)
        return Setup(folder: folder, notebook: notebook, coordinator: coordinator, overlay: overlay, page: page)
    }

    /// What the keyboard does: change the text, then tell the delegate.
    private func type(_ text: String, in setup: Setup) throws {
        let view = try #require(setup.coordinator.editingTextView as? TextBoxEditorView)
        view.text = text
        setup.coordinator.textViewDidChange(view)
    }

    @Test func theTextToolStopsInkAndListensForTaps() throws {
        let setup = try makeSetup()
        #expect(!setup.overlay.canvas.drawingGestureRecognizer.isEnabled)
        #expect(setup.overlay.textTap.isEnabled)
        #expect(!setup.overlay.objectGesture.isEnabled)
    }

    @Test func typingIntoANewBoxAddsOneUndoStepWhenTypingEnds() throws {
        let setup = try makeSetup()
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 200), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        try type("Hello\nworld", in: setup)
        #expect(!setup.notebook.undoManager.canUndo)  // letters never reach the notebook's history
        #expect(setup.notebook.objects(on: setup.page).isEmpty)

        setup.coordinator.endTextEditing()

        let objects = setup.notebook.objects(on: setup.page)
        #expect(objects.count == 1)
        guard case .text(let text) = objects[0].content else { Issue.record("not text"); return }
        #expect(text.text == "Hello\nworld" && text.fontSize == 20 && text.colorHex == "#1E5BFF")
        #expect(objects[0].frame.height == TextBoxLayout.height(of: text, width: objects[0].frame.width))
        #expect(setup.notebook.undoManager.undoActionName == "Add Text")
        #expect(setup.coordinator.editingTextView == nil)
        #expect(setup.overlay.subviews.allSatisfy { !($0 is TextBoxEditorView) })
        setup.notebook.undoManager.undo()
        #expect(setup.notebook.objects(on: setup.page).isEmpty)
    }

    @Test func anEmptyNewBoxIsNotKept() throws {
        let setup = try makeSetup()
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 200), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        try type("   ", in: setup)
        setup.coordinator.endTextEditing()
        #expect(setup.notebook.objects(on: setup.page).isEmpty)
        #expect(!setup.notebook.undoManager.canUndo)
    }

    @Test func editingAnExistingBoxIsOneStepAndEmptyingItDeletesIt() throws {
        let setup = try makeSetup()
        let box = textObject("Old", frame: CGRect(x: 50, y: 50, width: 200, height: 30))
        setup.notebook.addObject(box, to: setup.page, actionName: "Add")

        setup.coordinator.beginTextEditing(box, isNew: false, on: setup.overlay)
        #expect(setup.overlay.objectViews[box.id]?.isHidden == true)  // the text view stands in for it
        try type("New text", in: setup)
        setup.coordinator.endTextEditing()
        #expect(setup.notebook.undoManager.undoActionName == "Edit Text")
        #expect(setup.overlay.objectViews[box.id]?.isHidden == false)
        if case .text(let text) = setup.notebook.objects(on: setup.page)[0].content { #expect(text.text == "New text") }

        setup.coordinator.beginTextEditing(setup.notebook.objects(on: setup.page)[0], isNew: false, on: setup.overlay)
        try type("", in: setup)
        setup.coordinator.endTextEditing()
        #expect(setup.notebook.objects(on: setup.page).isEmpty)
    }

    @Test func pickingAnotherToolFinishesTyping() throws {
        let setup = try makeSetup()
        let box = setup.coordinator.newTextBox(at: CGPoint(x: 100, y: 200), pageSize: setup.overlay.bounds.size)
        setup.coordinator.beginTextEditing(box, isNew: true, on: setup.overlay)
        try type("Kept", in: setup)

        setup.coordinator.apply(settings: ToolSettings(), isRulerActive: false)  // the pen

        #expect(setup.coordinator.editingTextView == nil)
        #expect(setup.notebook.objects(on: setup.page).count == 1)
    }

    @Test func aNewBoxStaysOnThePage() throws {
        let setup = try makeSetup()
        let atEdge = setup.coordinator.newTextBox(at: CGPoint(x: 590, y: 840), pageSize: setup.overlay.bounds.size)
        #expect(atEdge.frame.maxX <= 595 && atEdge.frame.maxY <= 842)
        #expect(atEdge.frame.width >= TextBoxLayout.minimumWidth)
    }

    @Test func aBiggerFontMakesTheBoxTaller() throws {
        let setup = try makeSetup(tool: .select)
        let box = textObject("Some words", frame: CGRect(x: 50, y: 50, width: 200, height: 30), size: 12)
        setup.notebook.addObject(box, to: setup.page, actionName: "Add")
        setup.coordinator.changeText(of: box, on: setup.page, actionName: "Font Size") { $0.fontSize = 40 }
        let changed = setup.notebook.objects(on: setup.page)[0]
        #expect(changed.frame.height > box.frame.height * 2)
        #expect(setup.notebook.undoManager.undoActionName == "Font Size")
    }
}

struct TextToolSettingsTests {
    @Test func textSettingsAreSavedAndOldSettingsGetDefaults() throws {
        var settings = ToolSettings()
        settings.textFontSize = 24
        settings.textColorHex = "#E5484D"
        settings.selected = .text
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.textFontSize == 24 && decoded.textColorHex == "#E5484D" && decoded.selected == .text)

        let old = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"version": 1}"#.utf8))
        #expect(old.textFontSize == TextObject.defaultFontSize && old.textColorHex == "#000000")
    }
}
