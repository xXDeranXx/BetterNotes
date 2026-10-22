import PencilKit
import UIKit

/// A `PKCanvasView` that never takes part in undo and never becomes first responder.
///
/// - PencilKit registers its own undo steps on the canvas's `undoManager`. Those steps
///   would point at this canvas, which is dropped while scrolling (SPEC, decision 1). So the
///   canvas gets a manager that ignores every registration; undo lives in `Notebook`.
/// - The tool picker belongs to the editor's long-lived view, not to a page's canvas.
///   If a canvas became first responder, the picker would vanish when that canvas is dropped.
final class PageCanvasView: PKCanvasView {
    private let ignoredUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { ignoredUndoManager }
    override var canBecomeFirstResponder: Bool { false }
}

/// A transparent layer that lets every touch through to the views below it.
final class PassthroughView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// What PDFKit puts on top of each visible page (SPEC, decision 3). From bottom to top:
/// an objects layer (empty until milestone 8), the canvas, and a preview layer (live shapes,
/// milestone 7). Later features add content to a layer, not new view structure.
final class PageOverlayView: UIView {
    let pageID: UUID
    let objectsLayer = PassthroughView()
    let canvas = PageCanvasView()
    let previewLayer = PassthroughView()

    init(pageID: UUID) {
        self.pageID = pageID
        super.init(frame: .zero)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Pages stay white in dark mode, so ink must be drawn as on white paper.
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput  // the simulator has no Pencil
        #else
        canvas.drawingPolicy = .pencilOnly  // the Pencil writes, fingers scroll and zoom
        #endif

        for layer in [objectsLayer, canvas, previewLayer] as [UIView] {
            layer.frame = bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(layer)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
