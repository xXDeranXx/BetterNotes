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

/// A layer that holds interactive views (a text box being typed in) but lets every touch that
/// misses them through, like `pointer-events: none` on a container in CSS.
final class PassthroughContainer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// What PDFKit puts on top of each visible page (SPEC, decision 3). From bottom to top:
/// an objects layer (images and text boxes, milestone 8), the canvas, and a preview layer (live shapes,
/// milestone 7). Later features add content to a layer, not new view structure.
///
/// **Board mode** (whiteboards, `boardSize` set): the overlay fills the editor instead of a
/// page, and the canvas is its own scroll view over the whole board (PencilKit then renders
/// only what is on screen, see "Whiteboard spike"). The objects, preview and editing layers are
/// board-sized "page space" views that follow the canvas's scroll and zoom
/// (`syncBoardLayers`), so everything that works in page points (gestures, objects, shapes,
/// text) works unchanged: it reads and writes in `pageSpace`. In a notebook `pageSpace` is the
/// overlay itself, so nothing changes there.
final class PageOverlayView: UIView {
    let pageID: UUID
    /// The whiteboard's size in points; nil for a notebook page.
    let boardSize: CGSize?
    var isBoard: Bool { boardSize != nil }
    let objectsLayer = PassthroughView()
    private(set) var canvas: PageCanvasView
    let previewLayer = PassthroughView()
    /// Board mode only: holds the text box being typed in, above the ink, in page space.
    let editingLayer = PassthroughContainer()

    /// The view whose coordinates are page points: the overlay on a notebook page, the
    /// board-sized layers on a whiteboard.
    var pageSpace: UIView { isBoard ? objectsLayer : self }
    /// Where interactive page-space views go (the text box being typed in, the edit menu).
    var editingHost: UIView { isBoard ? editingLayer : self }

    init(pageID: UUID, boardSize: CGSize? = nil) {
        self.pageID = pageID
        self.boardSize = boardSize
        canvas = Self.makeCanvas(boardSize: boardSize)
        super.init(frame: .zero)

        let layers: [UIView] = boardSize == nil
            ? [objectsLayer, canvas, previewLayer]
            : [objectsLayer, canvas, previewLayer, editingLayer]
        for layer in layers {
            layer.frame = bounds
            addSubview(layer)
        }
        if let boardSize {
            backgroundColor = .white
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Page space: board-sized, pinned at the top-left corner (anchor 0, 0), so that its
            // position is simply minus the canvas's scroll offset and its transform the zoom.
            for layer in [objectsLayer, previewLayer, editingLayer] {
                layer.layer.anchorPoint = .zero
                layer.bounds = CGRect(origin: .zero, size: boardSize)
                layer.center = .zero
            }
        } else {
            // The canvas is laid out by hand (see `layoutSubviews`); the other layers follow the page.
            for layer in [objectsLayer, previewLayer] {
                layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
        }
        setUpShapePreview()
        for gesture in [shapeGesture, objectGesture, textTap, holdGesture] as [PageSpaceGesture] {
            gesture.pageSpace = pageSpace
        }
    }

    /// The size of the page in points (the board on a whiteboard).
    var pageSize: CGSize { boardSize ?? bounds.size }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeCanvas(boardSize: CGSize?) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Pages stay white in dark mode, so ink must be drawn as on white paper.
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = boardSize != nil
        canvas.contentInsetAdjustmentBehavior = .never
        if let boardSize {
            canvas.contentSize = boardSize
            canvas.minimumZoomScale = Whiteboard.minimumZoom
            canvas.maximumZoomScale = Whiteboard.maximumZoom
            canvas.bouncesZoom = false
            canvas.showsHorizontalScrollIndicator = false
            canvas.showsVerticalScrollIndicator = false
            // Fingers scroll and zoom; the Pencil never does, also while PencilKit's drawing is
            // switched off for the shape, select and text tools (it would scroll the board).
            let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            canvas.panGestureRecognizer.allowedTouchTypes = fingers
            canvas.pinchGestureRecognizer?.allowedTouchTypes = fingers
        }
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
        // Taken first: setting up the new canvas scrolls it, and `syncBoardLayers` then moves the
        // retired canvas along (measured: the old place was lost that way).
        let boardZoom = old.zoomScale, boardOffset = old.contentOffset
        let new = Self.makeCanvas(boardSize: boardSize)
        new.delegate = old.delegate
        new.tool = old.tool
        new.isRulerActive = old.isRulerActive
        new.drawingPolicy = old.drawingPolicy
        new.drawingGestureRecognizer.isEnabled = old.drawingGestureRecognizer.isEnabled  // off while drawing shapes
        new.isUserInteractionEnabled = old.isUserInteractionEnabled  // off with the select and text tools
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
        if isBoard {
            // The same place on the board, at the same zoom, before the drawing (M2 lesson).
            new.frame = bounds
            new.zoomScale = boardZoom
        }
        setNeedsLayout()
        layoutIfNeeded()  // size and zoom first, then the drawing (SPEC, M2 lesson)
        if isBoard {
            // Only after the layout has the content grown with the zoom; set earlier, the offset
            // was cut back to the unzoomed board (measured in a test).
            new.layoutIfNeeded()
            new.contentOffset = boardOffset
            syncBoardLayers()
        }
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
        if isBoard {
            // The canvas scrolls and zooms by itself and stays sharp; no `renderScale` here.
            syncBoardLayers()
            return
        }
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

    // MARK: Board mode

    /// Moves the page-space layers with the canvas (called on every scroll and zoom), and a
    /// canvas that is being retired along with them.
    func syncBoardLayers() {
        guard isBoard else { return }
        let zoom = canvas.zoomScale
        let offset = canvas.contentOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [objectsLayer, previewLayer, editingLayer] {
            layer.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            layer.center = CGPoint(x: -offset.x, y: -offset.y)
        }
        if let retiredCanvas {
            if retiredCanvas.zoomScale != zoom { retiredCanvas.zoomScale = zoom }
            retiredCanvas.contentOffset = offset
        }
        CATransaction.commit()
    }

    /// The board's pattern, behind the objects (they and the ink lie on top of it).
    var boardBackground: BoardBackground = .plain {
        didSet { if boardBackground != oldValue { updateBoardSharpness() } }
    }
    private var patternScale: CGFloat = 0

    /// After a zoom ends: the pattern and hand-drawn layers are redrawn for the new zoom, so they
    /// are as sharp as the ink. (Not on every frame of a pinch: that would cost CPU.)
    func updateBoardSharpness() {
        guard isBoard else { return }
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let scale = screenScale * max(1, canvas.zoomScale.rounded(.up))
        if scale != patternScale || objectsLayer.backgroundColor == nil && boardBackground != .plain {
            patternScale = scale
            objectsLayer.backgroundColor = Whiteboard.patternTile(boardBackground, scale: scale).map(UIColor.init(patternImage:)) ?? .clear
        }
        for layer in [fillPreview, outlinePreview, selectionOutline, selectionHandles] where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        for case let box as TextBoxView in objectsLayer.subviews where box.contentScaleFactor != scale {
            box.contentScaleFactor = scale
        }
    }

    /// The part of the board on screen, in page points.
    var visibleBoardRect: CGRect {
        let zoom = max(canvas.zoomScale, 0.01)
        return CGRect(
            x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom,
            width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
    }

    /// Shows the board at `zoom` (clamped) with the page point `point` at the top-left corner.
    func showBoard(at point: CGPoint, zoom: CGFloat) {
        guard let boardSize else { return }
        let zoom = min(max(zoom, Whiteboard.minimumZoom), Whiteboard.maximumZoom)
        if canvas.zoomScale != zoom { canvas.zoomScale = zoom }
        let maxX = max(0, boardSize.width * zoom - canvas.bounds.width)
        let maxY = max(0, boardSize.height * zoom - canvas.bounds.height)
        canvas.contentOffset = CGPoint(x: min(max(point.x * zoom, 0), maxX), y: min(max(point.y * zoom, 0), maxY))
        syncBoardLayers()
        updateBoardSharpness()
    }

    /// The middle of the board in the middle of the screen, at zoom 1 (where a new board opens).
    func showBoardCenter() {
        guard let boardSize else { return }
        showBoard(
            at: CGPoint(x: (boardSize.width - canvas.bounds.width) / 2, y: (boardSize.height - canvas.bounds.height) / 2),
            zoom: 1)
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
        if isBoard { updateBoardSharpness() }
    }

    /// Moves an object's view while it is dragged; the model changes when the drag ends.
    func previewObjectFrame(_ frame: CGRect, for id: UUID) {
        objectViews[id]?.frame = frame
    }

    // MARK: Selecting objects (M8)

    /// Reads drags on objects while the select tool is on (see `ObjectDragGesture`).
    let objectGesture = ObjectDragGesture()
    /// A finger held on an object selects it with any tool; on an empty spot it offers Paste.
    let objectLongPress = UILongPressGestureRecognizer()
    /// A tap with the text tool places or edits a text box (Pencil or finger). It does not
    /// take the touches away from a text box being typed in.
    let textTap = PageTapGesture()
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
        textTap.isEnabled = false
        textTap.cancelsTouchesInView = false
        textTap.delegate = self
        addGestureRecognizer(textTap)
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

/// A gesture that reports positions in page points, read in its `pageSpace` view (the overlay
/// on a notebook page, the board-sized layers on a whiteboard).
protocol PageSpaceGesture: AnyObject {
    var pageSpace: UIView? { get set }
}

/// Follows one drag on the page while the shape tool is on.
///
/// Gesture recognizers compete for a touch: by default, the first one that recognizes wins and
/// the others fail. PDFView's scrolling pan only recognizes after the touch has moved a bit, so
/// this recognizer starts the moment the Pencil touches down and wins; a finger still scrolls,
/// because only the Pencil is allowed (fingers too when finger drawing is on, and in the
/// simulator, which has no Pencil).
final class ShapeDragGesture: UIGestureRecognizer, PageSpaceGesture {
    /// Positions are read in this view (page points); nil means the gesture's own view.
    weak var pageSpace: UIView?

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
        startLocation = touch.location(in: pageSpace ?? view)
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
        return trackedTouch.location(in: pageSpace ?? view)
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
final class ObjectDragGesture: UIGestureRecognizer, PageSpaceGesture {
    /// Positions are read in this view (page points); nil means the gesture's own view.
    weak var pageSpace: UIView?

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
        let location = touch.location(in: pageSpace ?? view)
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
        let now = trackedTouch.location(in: pageSpace ?? view)
        return CGPoint(x: now.x - startLocation.x, y: now.y - startLocation.y)
    }
}

/// A tap on the page (Pencil or finger), for the text tool. UIKit's own tap recognizer never
/// fired on the page in the simulator (PDFView's and PencilKit's gestures win over it), so this
/// one is written like the drag gestures above: it watches one touch and recognizes on lift if
/// the touch stayed put. A moving finger fails it, so the page still scrolls.
final class PageTapGesture: UIGestureRecognizer, PageSpaceGesture {
    /// Positions are read in this view (page points); nil means the gesture's own view.
    weak var pageSpace: UIView?

    private var trackedTouch: UITouch?
    private var startOnGlass: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private(set) var location: CGPoint = .zero
    /// A touch held this long is not a tap (a finger held still asks for Paste instead).
    static let maximumDuration: TimeInterval = 0.5

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [UITouch.TouchType.pencil, .direct].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = .failed  // two fingers: a pinch or an undo tap
            return
        }
        trackedTouch = touch
        startOnGlass = touch.location(in: nil)
        startTime = touch.timestamp
        location = touch.location(in: pageSpace ?? view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let glass = trackedTouch.location(in: nil)
        if hypot(glass.x - startOnGlass.x, glass.y - startOnGlass.y) > 10 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        location = trackedTouch.location(in: pageSpace ?? view)
        guard trackedTouch.timestamp - startTime < Self.maximumDuration else {
            state = .failed
            return
        }
        state = .ended  // a discrete gesture: recognized in one step
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
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
final class HoldToSnapGesture: UIGestureRecognizer, PageSpaceGesture {
    /// Positions are read in this view (page points); nil means the gesture's own view.
    weak var pageSpace: UIView?

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
        points = [touch.location(in: pageSpace ?? view)]
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
                points.append(touch.location(in: pageSpace ?? view))
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
        return trackedTouch.location(in: pageSpace ?? view)
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
        holdLocation = trackedTouch.location(in: pageSpace ?? view)
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
        // Never stop scrolling or zooming, and never lose a tap to PDFView's own tap gestures.
        if gestureRecognizer === objectLongPress || gestureRecognizer === textTap { return true }
        return gestureRecognizer === holdGesture
            && (other === canvas.drawingGestureRecognizer || other === retiredCanvas?.drawingGestureRecognizer)
    }
}
