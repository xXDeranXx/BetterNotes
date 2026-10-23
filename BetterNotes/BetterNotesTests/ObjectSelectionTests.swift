import Foundation
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

struct ObjectEditingTests {
    private let picture = imageObject(file: "a.png", frame: CGRect(x: 100, y: 100, width: 200, height: 100))
    private let page = CGSize(width: 595, height: 842)

    @Test func theTopmostObjectWins() {
        let below = imageObject(file: "b.png", frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let above = textObject("x", frame: CGRect(x: 150, y: 150, width: 50, height: 20))
        #expect(ObjectEditing.object(at: CGPoint(x: 160, y: 160), in: [below, above])?.id == above.id)
        #expect(ObjectEditing.object(at: CGPoint(x: 10, y: 10), in: [below, above])?.id == below.id)
        #expect(ObjectEditing.object(at: CGPoint(x: 500, y: 500), in: [below, above]) == nil)
        // The slop widens a thin box.
        #expect(ObjectEditing.object(at: CGPoint(x: 160, y: 173), in: [above], slop: 4)?.id == above.id)
    }

    @Test func imagesHaveCornerHandlesAndTextBoxesSideHandles() {
        #expect(ObjectEditing.handles(for: picture) == [.topLeft, .topRight, .bottomLeft, .bottomRight])
        #expect(ObjectEditing.handles(for: textObject("x", frame: .zero)) == [.left, .right])
        #expect(ObjectEditing.handle(at: CGPoint(x: 298, y: 203), of: picture, radius: 10) == .bottomRight)
        #expect(ObjectEditing.handle(at: CGPoint(x: 200, y: 150), of: picture, radius: 10) == nil)
    }

    @Test func movingKeepsPartOfTheObjectOnThePage() {
        let moved = ObjectEditing.moved(picture.frame, by: CGPoint(x: 10, y: -20), pageSize: page)
        #expect(moved == CGRect(x: 110, y: 80, width: 200, height: 100))
        let far = ObjectEditing.moved(picture.frame, by: CGPoint(x: -1000, y: 5000), pageSize: page)
        #expect(far.maxX == ObjectEditing.minimumVisible)
        #expect(far.minY == page.height - ObjectEditing.minimumVisible)
    }

    @Test func cornerResizeKeepsProportionsAndTheOppositeCorner() {
        let bigger = ObjectEditing.resized(picture.frame, handle: .bottomRight, by: CGPoint(x: 100, y: 0))
        #expect(bigger == CGRect(x: 100, y: 100, width: 300, height: 150))
        let fromTopLeft = ObjectEditing.resized(picture.frame, handle: .topLeft, by: CGPoint(x: 100, y: 0))
        #expect(fromTopLeft.maxX == 300 && fromTopLeft.maxY == 200)
        #expect(abs(fromTopLeft.width / fromTopLeft.height - 2) < 0.001)
        // Never smaller than the minimum.
        let tiny = ObjectEditing.resized(picture.frame, handle: .bottomRight, by: CGPoint(x: -1000, y: -1000))
        #expect(tiny.height == ObjectEditing.minimumSize && tiny.width == 2 * ObjectEditing.minimumSize)
    }

    @Test func sideHandlesOnlyChangeTheWidth() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 40)
        #expect(ObjectEditing.resized(frame, handle: .right, by: CGPoint(x: 50, y: 30)) == CGRect(x: 100, y: 100, width: 250, height: 40))
        #expect(ObjectEditing.resized(frame, handle: .left, by: CGPoint(x: 50, y: 0)) == CGRect(x: 150, y: 100, width: 150, height: 40))
        #expect(ObjectEditing.resized(frame, handle: .left, by: CGPoint(x: 500, y: 0), minimumWidth: 40).width == 40)
    }
}

@MainActor
struct ObjectSelectionTests {
    private struct Setup {
        let folder: TempFolder
        let notebook: Notebook
        let coordinator: EditorCoordinator
        let overlay: PageOverlayView
        let page: UUID
    }

    private func makeSetup() throws -> Setup {
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
        settings.selected = .select
        coordinator.apply(settings: settings, isRulerActive: false)
        return Setup(folder: folder, notebook: notebook, coordinator: coordinator, overlay: overlay, page: page)
    }

    @Test func theSelectToolStopsInkAndListensForObjects() throws {
        let setup = try makeSetup()
        #expect(!setup.overlay.canvas.drawingGestureRecognizer.isEnabled)
        #expect(setup.overlay.objectGesture.isEnabled)
        #expect(setup.overlay.objectLongPress.isEnabled)  // only for Paste on an empty spot

        var pen = ToolSettings()
        pen.selected = .pen(.pen)
        setup.coordinator.apply(settings: pen, isRulerActive: false)
        #expect(setup.overlay.canvas.drawingGestureRecognizer.isEnabled)
        #expect(!setup.overlay.objectGesture.isEnabled)
        #expect(setup.overlay.objectLongPress.isEnabled)  // a finger long press still selects
    }

    @Test func aTouchOnAnObjectSelectsItAndATouchElsewhereLetsThePageScroll() throws {
        let setup = try makeSetup()
        let box = textObject("Hi", frame: CGRect(x: 100, y: 100, width: 200, height: 30))
        setup.notebook.addObject(box, to: setup.page, actionName: "Add")
        var cleared = 0
        setup.coordinator.onSelectionCleared = { cleared += 1 }

        #expect(setup.coordinator.objectTouchBegan(at: CGPoint(x: 150, y: 110), on: setup.overlay))
        #expect(setup.coordinator.selection == ObjectSelection(pageID: setup.page, objectID: box.id))
        #expect(setup.overlay.isShowingSelection)

        #expect(!setup.coordinator.objectTouchBegan(at: CGPoint(x: 400, y: 600), on: setup.overlay))
        #expect(setup.coordinator.selection == nil)
        #expect(!setup.overlay.isShowingSelection)
        #expect(cleared == 1)
    }

    @Test func aTouchOnAHandleOfTheSelectionStartsAResize() throws {
        let setup = try makeSetup()
        let picture = imageObject(file: "a.png", frame: CGRect(x: 100, y: 100, width: 200, height: 100))
        setup.notebook.addObject(picture, to: setup.page, actionName: "Add")
        _ = setup.coordinator.objectTouchBegan(at: CGPoint(x: 200, y: 150), on: setup.overlay)
        #expect(setup.coordinator.objectDrag?.handle == nil)

        _ = setup.coordinator.objectTouchBegan(at: CGPoint(x: 305, y: 205), on: setup.overlay)
        #expect(setup.coordinator.objectDrag?.handle == .bottomRight)
    }

    @Test func undoingTheObjectAwayEndsTheSelection() throws {
        let setup = try makeSetup()
        let box = textObject("Hi", frame: CGRect(x: 100, y: 100, width: 200, height: 30))
        setup.notebook.addObject(box, to: setup.page, actionName: "Add")
        _ = setup.coordinator.objectTouchBegan(at: CGPoint(x: 150, y: 110), on: setup.overlay)

        setup.notebook.undoManager.undo()
        #expect(setup.coordinator.selection == nil)
        #expect(setup.overlay.objectViews.isEmpty)
    }

    @Test func switchingToAnotherToolEndsTheSelectionQuietly() throws {
        let setup = try makeSetup()
        setup.notebook.addObject(textObject("Hi", frame: CGRect(x: 100, y: 100, width: 200, height: 30)), to: setup.page, actionName: "Add")
        _ = setup.coordinator.objectTouchBegan(at: CGPoint(x: 150, y: 110), on: setup.overlay)
        var cleared = 0
        setup.coordinator.onSelectionCleared = { cleared += 1 }

        setup.coordinator.apply(settings: ToolSettings(), isRulerActive: false)
        #expect(setup.coordinator.selection == nil)
        #expect(cleared == 0)  // the user picked the tool; nothing to switch back
    }
}

@MainActor
struct TemporarySelectToolTests {
    @Test func aLongPressSwitchesToSelectAndBackWhenTheSelectionEnds() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let tools = ToolController(store: ToolSettingsStore(defaults: defaults))
        tools.select(.pen(.marker))
        tools.beginTemporaryObjectSelection()
        #expect(tools.settings.selected == .select)
        tools.endTemporaryObjectSelection()
        #expect(tools.settings.selected == .pen(.marker))
    }

    @Test func choosingTheSelectToolByHandKeepsIt() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let tools = ToolController(store: ToolSettingsStore(defaults: defaults))
        tools.select(.select)
        tools.beginTemporaryObjectSelection()
        tools.endTemporaryObjectSelection()
        #expect(tools.settings.selected == .select)

        // A tool picked while a long-press selection is active also stays.
        tools.select(.pen(.pen))
        tools.beginTemporaryObjectSelection()
        tools.select(.eraser)
        tools.endTemporaryObjectSelection()
        #expect(tools.settings.selected == .eraser)
    }
}
