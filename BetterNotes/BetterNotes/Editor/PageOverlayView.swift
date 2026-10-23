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
    private(set) var canvas = PageOverlayView.makeCanvas()
    let previewLayer = PassthroughView()

    init(pageID: UUID) {
        self.pageID = pageID
        super.init(frame: .zero)

        for layer in [objectsLayer, canvas, previewLayer] as [UIView] {
            layer.frame = bounds
            addSubview(layer)
        }
        // The canvas is laid out by hand (see `layoutSubviews`); the other layers follow the page.
        for layer in [objectsLayer, previewLayer] {
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeCanvas() -> PageCanvasView {
        let canvas = PageCanvasView()
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
        return canvas
    }

    /// Swaps the canvas for a new, empty one at the same place and returns it.
    ///
    /// Needed when the page's ink changes from outside (undo, redo): assigning `drawing` to a
    /// canvas that the user has drawn on does not fully reset PencilKit's own copy of the
    /// strokes. The canvas reports the new drawing, but the next stroke is added to the old
    /// one, so an undone stroke came back (measured with a UI test in the simulator, also on
    /// the code of milestone 5; reported on the iPad). A fresh canvas has no such history.
    ///
    /// A new canvas draws its ink a moment later, so swapping straight away made the page
    /// flicker (empty for a frame or two, seen on the iPad). The old canvas therefore stays on
    /// top, still showing the old ink, until the new one has finished rendering
    /// (`retireOldCanvas`, called from `canvasViewDidFinishRendering`), or at the latest after
    /// `retireTimeout`. It takes no touches meanwhile, so the Pencil already writes on the new one.
    @discardableResult
    func replaceCanvas() -> PageCanvasView {
        retireOldCanvas()  // a quick second undo: the first old canvas goes now
        let old = canvas
        let new = Self.makeCanvas()
        new.delegate = old.delegate
        new.tool = old.tool
        new.isRulerActive = old.isRulerActive
        new.drawingPolicy = old.drawingPolicy
        old.delegate = nil
        old.isUserInteractionEnabled = false
        insertSubview(new, belowSubview: old)
        retiredCanvas = old
        canvas = new
        setNeedsLayout()
        layoutIfNeeded()  // size and zoom first, then the drawing (SPEC, M2 lesson)
        let timeout = Self.retireTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak old] in
            guard let self, let old, self.retiredCanvas === old else { return }
            self.retireOldCanvas()
        }
        return new
    }

    /// The canvas that was replaced and still covers the new one (see `replaceCanvas`).
    private(set) var retiredCanvas: PageCanvasView?
    static let retireTimeout: TimeInterval = 0.6

    func retireOldCanvas() {
        retiredCanvas?.removeFromSuperview()
        retiredCanvas = nil
    }

    /// How much sharper than the page the canvas renders (1 = the page's own size).
    /// PencilKit draws ink at the resolution of its scroll view's `zoomScale`, and ignores
    /// `contentScaleFactor`. So the canvas is made `renderScale` times bigger, zoomed by the
    /// same factor, and shrunk back with a transform: it covers the page exactly, and the
    /// drawing's coordinates stay in unzoomed page points.
    var renderScale: CGFloat = 1 {
        didSet { if renderScale != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = renderScale
        canvas.transform = .identity  // frame and bounds are only meaningful without a transform
        canvas.bounds = CGRect(
            x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.minimumZoomScale = scale
        canvas.maximumZoomScale = scale
        if canvas.zoomScale != scale { canvas.zoomScale = scale }
        canvas.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
    }
}
