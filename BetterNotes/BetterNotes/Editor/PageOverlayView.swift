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

/// Draws a text box with `TextBoxLayout`, exactly as thumbnails and export draw it.
final class TextBoxView: UIView {
    var text: TextObject? {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw  // draw again when resized, instead of stretching the old picture
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let text else { return }
        // Pages are white in dark mode too.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            TextBoxLayout.draw(text, in: bounds)
        }
    }
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
/// an objects layer (images and text boxes, milestone 8), the canvas, and a preview layer (live shapes,
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
        setUpShapePreview()
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
        new.drawingGestureRecognizer.isEnabled = old.drawingGestureRecognizer.isEnabled  // off while drawing shapes
        old.delegate = nil
        old.isUserInteractionEnabled = false
        insertSubview(new, belowSubview: old)
        // Translucent ink (shape fills, the highlighter) would show twice, darker, while the two
        // canvases overlap (seen on the iPad as filled shapes flickering after every new shape).
        // So the new canvas waits almost invisible; it still renders its ink, and is shown fully
        // in the same moment the old one goes.
        new.alpha = Self.waitingAlpha
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
    /// Low enough that double translucent ink does not show, above zero so the canvas is still drawn.
    static let waitingAlpha: CGFloat = 0.01

    func retireOldCanvas() {
        // One transaction without animation: the new canvas appears exactly when the old one goes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.alpha = 1
        retiredCanvas?.removeFromSuperview()
        CATransaction.commit()
        retiredCanvas = nil
        if clearsPreviewOnRetire { clearShapePreview() }
    }

    // MARK: Shapes

    /// Reads the Pencil's drag while the shape tool is on (see `ShapeDragGesture`).
    let shapeGesture = ShapeDragGesture()
    /// Draws the shape in progress on the preview layer. A `CAShapeLayer` is a Core Animation
    /// layer that draws a vector path (like an SVG `<path>`); changing its path redraws it cheaply.
    private let fillPreview = CAShapeLayer()
    private let outlinePreview = CAShapeLayer()
    private var clearsPreviewOnRetire = false

    private func setUpShapePreview() {
        for layer in [fillPreview, outlinePreview] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            previewLayer.layer.addSublayer(layer)
        }
        shapeGesture.isEnabled = false
        addGestureRecognizer(shapeGesture)
        holdGesture.isEnabled = false
        holdGesture.delegate = self
        addGestureRecognizer(holdGesture)
        setUpObjectSelection()
    }

    /// Watches pen strokes for a hold (see `HoldToSnapGesture`).
    let holdGesture = HoldToSnapGesture()

    /// Shows `shape` on the preview layer, in the same points the strokes will get.
    func showShapePreview(_ shape: ShapeOutline?, color: UIColor, width: CGFloat) {
        clearsPreviewOnRetire = false
        let outline = UIBezierPath()
        for piece in shape?.pieces ?? [] { Self.add(piece, to: outline) }
        outlinePreview.path = outline.cgPath
        outlinePreview.strokeColor = color.cgColor
        outlinePreview.lineWidth = width
        // The fill's strokes cover exactly the inside up to the outline's middle, so the preview
        // just paints that area.
        let fill = UIBezierPath()
        if let points = shape?.area { Self.add(points, to: fill) }
        fillPreview.path = fill.cgPath
        fillPreview.strokeColor = nil
        fillPreview.fillColor = color.withAlphaComponent(ShapeGeometry.fillOpacity).cgColor
    }

    private static func add(_ points: [CGPoint], to path: UIBezierPath) {
        guard let first = points.first else { return }
        path.move(to: first)
        // A single point (a dot) needs a tiny segment, or the round cap is not drawn.
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        for point in points.dropFirst() { path.addLine(to: point) }
    }

    /// The shape went into the model and the canvas. It draws the new ink a moment later, so the
    /// preview stays until then (cleared by the coordinator when the canvas reports it rendered,
    /// or by `retireOldCanvas` when a swap is pending), at the latest after `retireTimeout`.
    func finishShapePreview() {
        clearsPreviewOnRetire = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retireTimeout) { [weak self] in
            guard let self, self.clearsPreviewOnRetire else { return }
            self.clearShapePreview()
        }
    }

    var isWaitingToClearPreview: Bool { clearsPreviewOnRetire }

    func clearShapePreview() {
        clearsPreviewOnRetire = false
        fillPreview.path = nil
        outlinePreview.path = nil
    }

    var isShowingShapePreview: Bool { outlinePreview.path.map { !$0.isEmpty } ?? false }

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
        // Layers made by hand draw at 1x unless told otherwise; PDFKit enlarges the overlay when
        // zoomed, so the shape preview renders as sharp as the ink.
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        for layer in [fillPreview, outlinePreview] where layer.contentsScale != screenScale * scale {
            layer.contentsScale = screenScale * scale
        }
        for layer in [selectionOutline, selectionHandles] where layer.contentsScale != screenScale * scale {
            layer.contentsScale = screenScale * scale
        }
        // Text boxes are drawn by hand too; render them as sharp as the ink.
        for case let box as TextBoxView in objectsLayer.subviews where box.contentScaleFactor != screenScale * scale {
            box.contentScaleFactor = screenScale * scale
        }
    }

    // MARK: Objects (M8)

    /// One view per object, by object id, in the objects layer below the ink.
    private(set) var objectViews: [UUID: UIView] = [:]

    /// Shows the page's objects, reusing the views of objects that are still there. Views are
    /// in the objects' order, so a later object lies on top of an earlier one.
    func showObjects(_ objects: [PageObject], image: (String) -> UIImage?) {
        var remaining = objectViews
        objectViews = [:]
        for object in objects {
            let view: UIView
            switch object.content {
            case .image(let content):
                let imageView = remaining[object.id] as? UIImageView ?? UIImageView()
                if imageView.accessibilityIdentifier != content.file {
                    imageView.accessibilityIdentifier = content.file
                    imageView.image = image(content.file)
                    // A missing file shows as a grey box, as in thumbnails and export.
                    imageView.backgroundColor = imageView.image == nil ? .systemGray5 : .clear
                }
                imageView.contentMode = .scaleToFill
                view = imageView
            case .text(let content):
                let box = remaining[object.id] as? TextBoxView ?? TextBoxView()
                box.text = content
                view = box
            }
            remaining[object.id] = nil
            view.frame = object.frame
            objectsLayer.addSubview(view)  // adding an existing subview moves it to the top
            objectViews[object.id] = view
        }
        for leftover in remaining.values { leftover.removeFromSuperview() }
        setNeedsLayout()  // new text boxes get their sharpness in layoutSubviews
    }

    /// Moves an object's view while it is dragged; the model changes when the drag ends.
    func previewObjectFrame(_ frame: CGRect, for id: UUID) {
        objectViews[id]?.frame = frame
    }

    // MARK: Selecting objects (M8)

    /// Reads drags on objects while the select tool is on (see `ObjectDragGesture`).
    let objectGesture = ObjectDragGesture()
    /// A finger held on an object selects it with any tool.
    let objectLongPress = UILongPressGestureRecognizer()
    /// The dashed frame and the handles around the selected object, above the ink.
    private let selectionOutline = CAShapeLayer()
    private let selectionHandles = CAShapeLayer()

    private func setUpObjectSelection() {
        objectGesture.isEnabled = false
        addGestureRecognizer(objectGesture)
        objectLongPress.isEnabled = false
        objectLongPress.minimumPressDuration = 0.5
        objectLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]  // fingers
        objectLongPress.delegate = self
        addGestureRecognizer(objectLongPress)
        selectionOutline.fillColor = nil
        selectionOutline.strokeColor = UIColor.systemBlue.cgColor
        selectionHandles.fillColor = UIColor.white.cgColor
        selectionHandles.strokeColor = UIColor.systemBlue.cgColor
        for layer in [selectionOutline, selectionHandles] { previewLayer.layer.addSublayer(layer) }
    }

    /// Shows the selection around `frame` (nil hides it). The overlay is enlarged by the zoom
    /// from outside, so lines and handles are divided by `zoom` to look the same size at any zoom.
    func showSelection(_ frame: CGRect?, handles: [CGPoint], zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // follow the Pencil without animation
        defer { CATransaction.commit() }
        guard let frame else {
            selectionOutline.path = nil
            selectionHandles.path = nil
            return
        }
        let unit = 1 / max(zoom, 0.01)
        selectionOutline.path = UIBezierPath(rect: frame).cgPath
        selectionOutline.lineWidth = 1.5 * unit
        selectionOutline.lineDashPattern = [NSNumber(value: Double(6 * unit)), NSNumber(value: Double(4 * unit))]
        let dots = UIBezierPath()
        for point in handles {
            dots.append(UIBezierPath(ovalIn: CGRect(x: point.x - 6 * unit, y: point.y - 6 * unit, width: 12 * unit, height: 12 * unit)))
        }
        selectionHandles.path = dots.cgPath
        selectionHandles.lineWidth = 1.5 * unit
    }

    var isShowingSelection: Bool { selectionOutline.path != nil }

    /// The resolution the shape preview draws at (tests).
    var shapePreviewScale: CGFloat { outlinePreview.contentsScale }
}

/// Follows one drag on the page while the shape tool is on.
///
/// Gesture recognizers compete for a touch: by default, the first one that recognizes wins and
/// the others fail. PDFView's scrolling pan only recognizes after the touch has moved a bit, so
/// this recognizer starts the moment the Pencil touches down and wins; a finger still scrolls,
/// because only the Pencil is allowed (fingers too when finger drawing is on, and in the
/// simulator, which has no Pencil).
final class ShapeDragGesture: UIGestureRecognizer {
    private(set) var startLocation: CGPoint = .zero
    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only touches of the allowed types arrive here, so a resting palm does not count.
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            // A second allowed touch (a pinch while finger drawing is on): not a shape.
            if trackedTouch == nil { state = .failed } else { state = .cancelled }
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }

    /// Where the tracked touch is now, in the page's points.
    var currentLocation: CGPoint {
        guard let trackedTouch, let view else { return startLocation }
        return trackedTouch.location(in: view)
    }

    /// Pencil only, or Pencil and fingers.
    func allowFingers(_ allowed: Bool) {
        var types: [UITouch.TouchType] = [.pencil]
        if allowed { types.append(.direct) }
        allowedTouchTypes = types.map { NSNumber(value: $0.rawValue) }
    }
}

/// Follows one drag on an object while the select tool is on (M8). Unlike the shape gesture
/// it only starts when `shouldBegin` says the touch is on an object (or a handle): a finger
/// that starts elsewhere fails it at once, so the page scrolls as usual.
final class ObjectDragGesture: UIGestureRecognizer {
    /// Asked with the touch's position in page points when a touch begins.
    var shouldBegin: ((CGPoint) -> Bool)?
    private(set) var startLocation: CGPoint = .zero
    /// True once the touch moved more than a few screen points: a drag, not a tap.
    private(set) var hasMoved = false
    private var trackedTouch: UITouch?
    private var startOnGlass: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [UITouch.TouchType.pencil, .direct].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            if trackedTouch == nil { state = .failed } else { state = .cancelled }  // a pinch
            return
        }
        let location = touch.location(in: view)
        guard shouldBegin?(location) == true else {
            state = .failed
            return
        }
        trackedTouch = touch
        startLocation = location
        startOnGlass = touch.location(in: nil)
        hasMoved = false
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let glass = trackedTouch.location(in: nil)
        if hypot(glass.x - startOnGlass.x, glass.y - startOnGlass.y) > 6 { hasMoved = true }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        hasMoved = false
    }

    /// How far the touch moved since it began, in page points.
    var translation: CGPoint {
        guard let trackedTouch, let view else { return .zero }
        let now = trackedTouch.location(in: view)
        return CGPoint(x: now.x - startLocation.x, y: now.y - startLocation.y)
    }
}

/// Listens to the Pencil while a pen writes, for "hold to snap" (M7). It runs **at the same
/// time** as PencilKit's own drawing gesture: normally only one gesture recognizer may handle
/// a touch, but the overlay's delegate method `shouldRecognizeSimultaneouslyWith` lets this one
/// watch the same touches while PencilKit draws (like two event listeners on one element in
/// JavaScript, where neither calls `stopPropagation`).
///
/// It stays in the `possible` state, only collecting points, until the Pencil has been held
/// still (`HoldDetector`, checked by a timer) and `shouldSnap` accepts the points as a shape.
/// Then it begins, reports every move while the Pencil follows the shape, and ends on lift.
/// A stroke that never snaps lets it fail quietly at the end; PencilKit keeps its stroke.
final class HoldToSnapGesture: UIGestureRecognizer {
    /// The stroke's points so far, in the overlay's coordinates, which are page points.
    private(set) var points: [CGPoint] = []
    /// Where the Pencil was held, in page points.
    private(set) var holdLocation: CGPoint = .zero
    /// Asked once a hold is detected; true starts the snap.
    var shouldSnap: (([CGPoint]) -> Bool)?

    private var detector = HoldDetector()
    private var trackedTouch: UITouch?
    private var timer: DispatchWorkItem?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false  // PencilKit must keep getting the touches
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            if state == .possible { state = .failed }  // a second touch: a pinch, not a stroke
            return
        }
        trackedTouch = touch
        points = [touch.location(in: view)]
        detector.reset()
        detector.add(touch.location(in: nil), at: touch.timestamp)
        scheduleHoldCheck()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        if state == .possible {
            // Coalesced touches: the Pencil reports up to 240 positions a second, more than
            // the screen shows; all of them keep a fast stroke's shape.
            let restBefore = detector.restTime
            for touch in event.coalescedTouches(for: trackedTouch) ?? [trackedTouch] {
                points.append(touch.location(in: view))
                // Stillness is judged on the glass (window points), not on the zoomed page.
                detector.add(touch.location(in: nil), at: touch.timestamp)
            }
            if detector.restTime != restBefore { scheduleHoldCheck() }
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        points = []
        detector.reset()
        timer?.cancel()
        timer = nil
    }

    /// Where the tracked touch is now, in page points.
    var currentLocation: CGPoint {
        guard let trackedTouch, let view else { return holdLocation }
        return trackedTouch.location(in: view)
    }

    /// Checks again when the Pencil would have rested long enough (it may send no touches at
    /// all while it does not move).
    private func scheduleHoldCheck() {
        timer?.cancel()
        guard let holdTime = detector.holdTime else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkHold() }
        timer = work
        let delay = max(0, holdTime - ProcessInfo.processInfo.systemUptime) + 0.005
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkHold() {
        guard state == .possible, let trackedTouch,
            detector.isHolding(at: ProcessInfo.processInfo.systemUptime)
        else { return }
        holdLocation = trackedTouch.location(in: view)
        if shouldSnap?(points) == true {
            state = .began
        } else {
            // Not a shape: keep writing. Only a new rest after moving can snap later.
            detector.reset()
        }
    }

    /// Pencil only, or Pencil and fingers (finger drawing on, and the simulator).
    func allowFingers(_ allowed: Bool) {
        var types: [UITouch.TouchType] = [.pencil]
        if allowed { types.append(.direct) }
        allowedTouchTypes = types.map { NSNumber(value: $0.rawValue) }
    }
}

extension PageOverlayView: UIGestureRecognizerDelegate {
    /// The hold gesture watches the same touches as PencilKit's drawing gesture (of the current
    /// canvas, or of the old one during a swap), and as nothing else, so it never lets the page
    /// scroll while a shape follows the Pencil.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Compared by identity: PencilKit may attach its gesture to an inner view of the canvas.
        if gestureRecognizer === objectLongPress { return true }  // never stops scrolling or zooming
        return gestureRecognizer === holdGesture
            && (other === canvas.drawingGestureRecognizer || other === retiredCanvas?.drawingGestureRecognizer)
    }
}
