import Observation
import PencilKit
import SwiftUI

/// The state of the pen toolbar for one editor window. The settings themselves belong to the
/// device (`ToolSettingsStore`, in `UserDefaults`); this class holds them while the editor is
/// open, saves every change, and is what the toolbar views read and write.
///
/// `@Observable` is like a React store: views that read a property are redrawn when it changes.
@Observable
final class ToolController {
    var settings: ToolSettings {
        didSet { if settings != oldValue { store.save(settings) } }
    }
    /// The straight-edge ruler is a switch on the canvas, not a tool, and is not remembered.
    var isRulerActive = false
    /// Shown by the Pencil's squeeze or double tap ("show color palette").
    var isPalettePresented = false
    /// Where the Pencil was when it was squeezed (in the editor's coordinates), so the palette
    /// opens next to it. `nil` = no position known.
    var palettePosition: CGPoint?

    @ObservationIgnored private let store: ToolSettingsStore
    /// The pen that was selected before the eraser was switched on, for "switch to previous".
    @ObservationIgnored private var toolBeforeEraser: ToolChoice?

    init(store: ToolSettingsStore = ToolSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    var currentPen: PenKind { settings.currentPen }
    var currentPenSetting: PenSetting { settings.setting(for: settings.currentPen) }

    func select(_ choice: ToolChoice) {
        if settings.selected != .eraser, choice == .eraser { toolBeforeEraser = settings.selected }
        settings.selected = choice
    }

    // MARK: The Pencil

    /// What squeeze and double tap do, following the setting the user made in iPadOS Settings.
    func perform(_ action: UIPencilPreferredAction, at position: CGPoint? = nil) {
        switch action {
        case .switchEraser:
            if settings.selected == .eraser { select(toolBeforeEraser ?? .pen(settings.enabledPens[0])) } else { select(.eraser) }
        case .switchPrevious:
            if let previous = toolBeforeEraser { let now = settings.selected; settings.selected = previous; toolBeforeEraser = now }
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            palettePosition = position
            isPalettePresented = true
        default:
            break  // ignore, run system shortcut, and anything newer: nothing to do
        }
    }
}
