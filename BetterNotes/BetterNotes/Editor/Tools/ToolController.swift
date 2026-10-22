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
    /// Returns `true` when the action is "show the palette", which the editor then opens next to
    /// the Pencil (a popover needs a view to point at, so it is not decided here).
    @discardableResult
    func perform(_ action: UIPencilPreferredAction) -> Bool {
        switch action {
        case .switchEraser:
            if settings.selected == .eraser { select(toolBeforeEraser ?? .pen(settings.enabledPens[0])) } else { select(.eraser) }
        case .switchPrevious:
            if let previous = toolBeforeEraser { let now = settings.selected; settings.selected = previous; toolBeforeEraser = now }
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            return true
        default:
            break  // ignore, run system shortcut, and anything newer: nothing to do
        }
        return false
    }
}
