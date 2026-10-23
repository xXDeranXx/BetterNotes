import PDFKit
import PencilKit
import UIKit

/// Connects the notebook model to the canvases PDFKit puts on the visible pages.
///
/// PDFKit asks `pageOverlayViewProvider` for a view per page and tells it when a page's view
/// goes on screen and when it is taken off again. We use those two calls to create canvases
/// lazily and drop them, so a 300-page PDF never holds 300 canvases.
///
/// The model is the truth: a canvas shows what the model says when it appears, and while it
/// is visible it reports finished strokes to the model and shows what the model says after
/// undo and redo.
final class EditorCoordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    let notebook: Notebook
    /// One tool picker per editor, shown for the editor's long-lived view (see
    /// `NotebookEditorViewController`), with the visible canvases as its observers.
    let toolPicker = PKToolPicker()
    private(set) var visibleOverlays: [UUID: PageOverlayView] = [:]

    /// What the own toolbar has selected (`ToolController`), applied to every visible canvas and
    /// to pages that scroll in later. Ignored while the system tool picker is in use.
    private(set) var tool: PKTool = PKInkingTool(.pen, color: .black, width: 3)
    private(set) var usesSystemToolPicker = false
    private(set) var isRulerActive = false
    private(set) var allowsFingerDrawing = false
    /// The shape tool's choices while it is selected, nil for every other tool.
    private(set) var shape: ShapeSetting?
    /// The pen in use while hold to snap or hold to smooth is on (and a pen of the own toolbar
    /// is selected), and which of the two are on.
    private(set) var snappingPen: (kind: PenKind, setting: PenSetting)?
    private var snapsShapes = false
    private var smoothsCurves = false
    private var lastApplication: ToolApplication?
    /// True while the select tool is on (M8): touches move objects, PencilKit does not draw.
    private(set) var selectsObjects = false
    /// The toolbar's favorite colors, for the text box color menu.
    private(set) var favoriteColors: [String] = ToolSettings.defaultFavorites
    /// The selected object, its page, and an edit in progress (see `EditorCoordinator+Objects`).
    var selection: ObjectSelection?
    var objectDrag: ObjectDrag?
    /// The editor switches tools for these (a long press on an object; the selection ended).
    var onLongPressObject: (() -> Void)?
    var onSelectionCleared: (() -> Void)?
    /// True while the text tool is on: a tap places or edits a text box (M8).
    private(set) var placesText = false
    /// Font, size, color and style of new text boxes, from the toolbar.
    private(set) var textFontSize = TextObject.defaultFontSize
    private(set) var textColorHex = "#000000"
    private(set) var textFont: TextFont = .system
    private(set) var textBold = false
    private(set) var textItalic = false
    /// Where a finger was held on an empty spot, for the Paste in the menu shown there.
    var pasteTarget: PasteTarget?
    /// The text box being typed in, if any (see `EditorCoordinator+Text`).
    var textEditing: TextEditing?
    /// Typing ended: the editor takes the keyboard focus back (Cmd+Z, the system tool picker).
    var onTextEditingEnded: (() -> Void)?
    private var lastSelectedTool: ToolChoice?

    /// What `configure` needs from the settings; selecting a tool or changing its color or
    /// width changes it, undo does not.
    private struct ToolApplication: Equatable {
        let settings: ToolSettings
        let isRulerActive: Bool
    }

    /// PDFKit gives every overlay the size of the page in points (595 x 842 for A4) at every
    /// zoom, and enlarges it from outside, so a canvas that renders at the page's own size
    /// looks soft when zoomed (see `PageOverlayView.renderScale`).
    /// Ink is drawn in tiles, so only what is on screen should cost memory. Tune the cap on
    /// the iPad; PDFView's own maximum zoom is 6.
    static let maxRenderScale: CGFloat = 6

    /// How many times larger than the page the canvas should render: the zoom, rounded up to
    /// a whole number so a pinch does not re-render on every frame. Never below 1 and never
    /// above `cap`.
    static func renderScale(zoom: CGFloat, cap: CGFloat = maxRenderScale) -> CGFloat {
        min(max(1, zoom.rounded(.up)), cap)
    }

    /// Ink resolution is the heaviest thing the app does, so it is also what we give up when
    /// the iPad reports that it is getting hot (`ProcessInfo.thermalState`). Sharpness returns
    /// by itself when the iPad has cooled down.
    static func renderScaleCap(for thermalState: ProcessInfo.ThermalState) -> CGFloat {
        switch thermalState {
        case .nominal, .fair: maxRenderScale
        case .serious: 2
        case .critical: 1
        @unknown default: 2
        }
    }

    private(set) var zoom: CGFloat = 1
    private(set) var thermalState: ProcessInfo.ThermalState
    private var thermalObserver: NSObjectProtocol?

    /// True while we copy a drawing between model and canvas. PencilKit calls the delegate,
    /// synchronously, when code assigns `canvas.drawing` (checked in the simulator). Without
    /// this flag that echo would count as a new stroke, add an undo step, and wipe the redo
    /// history.
    private var isSyncing = false

    init(notebook: Notebook, thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) {
        self.notebook = notebook
        self.thermalState = thermalState
        super.init()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.thermalStateDidChange(to: ProcessInfo.processInfo.thermalState)
            }
        }
        // One closure for the whole notebook. It looks up the canvas by page id.
        notebook.onDrawingChange = { [weak self] pageID in self?.modelDrawingChanged(pageID) }
        notebook.onObjectsChange = { [weak self] pageID in self?.modelObjectsChanged(pageID) }
        notebook.visiblePageIDs = { [weak self] in
            self.map { Set($0.visibleOverlays.keys) } ?? []
        }
    }

    // MARK: Page → page id

    /// The one place that maps a PDF page to its id. The notebook knows it by the page object,
    /// not by position: PDFKit asks for overlays while the PDF and the page list are still
    /// being changed together (see `Notebook.pageID(for:)`).
    func pageID(for page: PDFPage) -> UUID? {
        notebook.pageID(for: page)
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let pageID = pageID(for: page) else { return nil }
        let overlay = PageOverlayView(pageID: pageID)
        overlay.canvas.delegate = self
        overlay.renderScale = currentRenderScale
        overlay.shapeGesture.addTarget(self, action: #selector(shapeDragged(_:)))
        overlay.holdGesture.addTarget(self, action: #selector(holdSnapped(_:)))
        overlay.holdGesture.shouldSnap = { [weak self, weak overlay] points in
            guard let self, let overlay else { return false }
            return self.prepareSnap(points, on: overlay)
        }
        overlay.objectGesture.addTarget(self, action: #selector(objectDragged(_:)))
        overlay.objectGesture.shouldBegin = { [weak self, weak overlay] point in
            guard let self, let overlay else { return false }
            return self.objectTouchBegan(at: point, on: overlay)
        }
        overlay.objectLongPress.addTarget(self, action: #selector(objectLongPressed(_:)))
        overlay.textTap.addTarget(self, action: #selector(textTapped(_:)))
        overlay.addInteraction(UIEditMenuInteraction(delegate: self))
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        overlayDidAppear(overlay)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        overlayDidDisappear(overlay)
    }

    isolated deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    // MARK: Heat

    /// Called when the iPad's thermal state changes: lowers or restores the ink resolution of
    /// the visible canvases. Pages that scroll in later pick up the current state too.
    func thermalStateDidChange(to newState: ProcessInfo.ThermalState) {
        guard newState != thermalState else { return }
        thermalState = newState
        visibleOverlays.values.forEach(applyRenderScale)
    }

    // MARK: Zoom

    /// Called by the editor whenever the PDFView's zoom changes.
    func zoomDidChange(to newZoom: CGFloat) {
        guard newZoom != zoom else { return }
        zoom = newZoom
        visibleOverlays.values.forEach(applyRenderScale)
        refreshSelection()  // handles keep their size on screen
    }

    private var currentRenderScale: CGFloat {
        Self.renderScale(zoom: zoom, cap: Self.renderScaleCap(for: thermalState))
    }

    private func applyRenderScale(to overlay: PageOverlayView) {
        overlay.renderScale = currentRenderScale
    }

    // MARK: Showing and hiding

    func overlayDidAppear(_ overlay: PageOverlayView) {
        visibleOverlays[overlay.pageID] = overlay
        // The canvas must have its final size and zoom BEFORE it gets a drawing: PencilKit does
        // not redraw a drawing that was set before the canvas was magnified (the ink then
        // stayed invisible after reopening a notebook).
        applyRenderScale(to: overlay)
        overlay.layoutIfNeeded()
        configure(overlay)
        // The model may have changed while this page was off screen (undo), so always
        // load from the model, never trust what the canvas still holds.
        show(notebook.drawing(for: overlay.pageID), in: overlay.canvas)
        showObjects(on: overlay)
        if usesSystemToolPicker { toolPicker.addObserver(overlay.canvas) }
    }

    // MARK: Objects (M8)

    /// Decoded object images by file name. A 2000-pixel image takes about 16 MB once decoded,
    /// so only a few stay in memory; the system also empties the cache when memory is low.
    private let objectImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()

    func objectImage(named name: String) -> UIImage? {
        if let cached = objectImages.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: notebook.package.objectFileURL(named: name).path)?
            .preparingForDisplay()  // decode now, not while scrolling
        else { return nil }
        objectImages.setObject(image, forKey: name as NSString)
        return image
    }

    func showObjects(on overlay: PageOverlayView) {
        overlay.showObjects(notebook.objects(on: overlay.pageID)) { [weak self] in self?.objectImage(named: $0) }
    }

    /// Objects changed in the model (added, moved, undone): show them on the page if it is visible.
    private func modelObjectsChanged(_ pageID: UUID) {
        guard let overlay = visibleOverlays[pageID] else { return }
        showObjects(on: overlay)
        if selection?.pageID == pageID { refreshSelection() }
    }

    // MARK: Tools

    /// Called by the editor whenever the toolbar's settings change.
    ///
    /// SwiftUI calls this after every undo and every stroke too, not only when a tool changed.
    /// Touching a `PKCanvasView`'s tool or drawing policy right after a stroke or an undo is
    /// not harmless (an undone stroke came back on the iPad), so nothing is touched when the
    /// relevant settings are the same as the last time.
    func apply(settings: ToolSettings, isRulerActive: Bool) {
        let key = ToolApplication(settings: settings, isRulerActive: isRulerActive)
        guard key != lastApplication else { return }
        lastApplication = key
        let switchedPicker = settings.usesSystemToolPicker != usesSystemToolPicker
        tool = settings.makeTool()
        usesSystemToolPicker = settings.usesSystemToolPicker
        allowsFingerDrawing = settings.allowsFingerDrawing
        self.isRulerActive = isRulerActive
        shape = settings.selected == .shape && !settings.usesSystemToolPicker ? settings.shape : nil
        selectsObjects = settings.selected == .select && !settings.usesSystemToolPicker
        placesText = settings.selected == .text && !settings.usesSystemToolPicker
        textFontSize = settings.textFontSize
        textColorHex = settings.textColorHex
        textFont = settings.textFont
        textBold = settings.textBold
        textItalic = settings.textItalic
        favoriteColors = settings.favoriteColors
        // Another tool was picked: finish the text box being typed in.
        if settings.selected != lastSelectedTool { endTextEditing() }
        lastSelectedTool = settings.selected
        if !selectsObjects { clearSelection(notify: false) }
        snapsShapes = settings.holdToSnapShapes
        smoothsCurves = settings.holdToSmoothCurves
        if case .pen(let kind) = settings.selected, snapsShapes || smoothsCurves, !settings.usesSystemToolPicker {
            snappingPen = (kind, settings.setting(for: kind))
        } else {
            snappingPen = nil
        }
        for overlay in visibleOverlays.values {
            configure(overlay)
            if switchedPicker {
                if usesSystemToolPicker { toolPicker.addObserver(overlay.canvas) } else { toolPicker.removeObserver(overlay.canvas) }
            }
        }
    }

    private func configure(_ overlay: PageOverlayView) {
        let canvas = overlay.canvas
        if !usesSystemToolPicker { canvas.tool = tool }
        // While the shape tool is on, the shape gesture reads the Pencil and PencilKit must not
        // draw (SPEC, M2 spike: switching its gesture off is clean).
        let drawsShapes = shape != nil
        if canvas.drawingGestureRecognizer.isEnabled == blocksInk { canvas.drawingGestureRecognizer.isEnabled = !blocksInk }
        overlay.shapeGesture.isEnabled = drawsShapes
        overlay.objectGesture.isEnabled = selectsObjects
        overlay.textTap.isEnabled = placesText
        // With the select and text tools the canvas takes no touches at all: PencilKit's own
        // tap handling showed a Paste bubble and took the keyboard from a new text box.
        let canvasTakesTouches = !(selectsObjects || placesText)
        if canvas.isUserInteractionEnabled != canvasTakesTouches { canvas.isUserInteractionEnabled = canvasTakesTouches }
        // A finger long press selects an object, or offers Paste on an empty spot; not while
        // fingers draw. With the select tool it only offers Paste (drags own the objects there).
        overlay.objectLongPress.isEnabled = !allowsFingerDrawing && !usesSystemToolPicker
        #if targetEnvironment(simulator)
        overlay.shapeGesture.allowFingers(true)
        #else
        overlay.shapeGesture.allowFingers(allowsFingerDrawing)
        #endif
        // Not with the ruler: a ruler line must stay at the ruler's angle, not snap to 0 degrees.
        overlay.holdGesture.isEnabled = snappingPen != nil && !isRulerActive
        #if targetEnvironment(simulator)
        overlay.holdGesture.allowFingers(true)
        #else
        overlay.holdGesture.allowFingers(allowsFingerDrawing)
        #endif
        if canvas.isRulerActive != isRulerActive { canvas.isRulerActive = isRulerActive }
        #if !targetEnvironment(simulator)
        let policy: PKCanvasViewDrawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        #endif
    }

    /// PencilKit must not draw while the shape or the select tool reads the touches.
    private var blocksInk: Bool { shape != nil || selectsObjects || placesText }

    func overlayDidDisappear(_ overlay: PageOverlayView) {
        if textEditing?.pageID == overlay.pageID { endTextEditing() }  // before the page is forgotten
        visibleOverlays[overlay.pageID] = nil
        if selection?.pageID == overlay.pageID { clearSelection(notify: true) }
        if usesSystemToolPicker { toolPicker.removeObserver(overlay.canvas) }
        // SPEC, "Data safety": a changed page is also saved when its canvas leaves the screen.
        // Once that is done, drawings that are saved and off screen are dropped from memory.
        Task { [notebook] in
            await notebook.saveChanges()
            notebook.evictOffscreenDrawings()
        }
    }

    private func show(_ drawing: PKDrawing, in canvas: PKCanvasView) {
        isSyncing = true
        canvas.drawing = drawing
        isSyncing = false
    }

    // MARK: Model → canvas

    /// Undo and redo change the ink from outside. The canvas is replaced by a fresh one
    /// before it gets the new drawing (see `PageOverlayView.replaceCanvas`).
    private func modelDrawingChanged(_ pageID: UUID) {
        guard !isSyncing, let overlay = visibleOverlays[pageID] else { return }
        let old = overlay.canvas
        if usesSystemToolPicker { toolPicker.removeObserver(old) }
        let canvas = overlay.replaceCanvas()
        if usesSystemToolPicker { toolPicker.addObserver(canvas) }
        show(notebook.drawing(for: pageID), in: canvas)
    }

    /// PencilKit has drawn the canvas's ink: a canvas that was swapped in after an undo now
    /// shows the right ink, so the old one that covered it can go. PencilKit reports this
    /// about 40 ms after the drawing was assigned (measured), but removing the old canvas in
    /// that same moment still flickered on the iPad, so it waits `retireGracePeriod` longer.
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard let overlay = canvasView.superview as? PageOverlayView, overlay.canvas === canvasView else { return }
        if overlay.retiredCanvas == nil, overlay.isWaitingToClearPreview {
            // The canvas has drawn the new shape; the preview over it can go a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewGracePeriod) { [weak overlay] in
                guard let overlay, overlay.isWaitingToClearPreview else { return }
                overlay.clearShapePreview()
            }
        }
        guard let retired = overlay.retiredCanvas else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retireGracePeriod) { [weak overlay, weak retired] in
            guard let overlay, let retired, overlay.retiredCanvas === retired else { return }
            overlay.retireOldCanvas()
        }
    }

    static let retireGracePeriod: TimeInterval = 0.1
    /// Shorter than `retireGracePeriod`: preview and ink overlap only for the one new shape.
    static let previewGracePeriod: TimeInterval = 0.05

    /// The Pencil touches the page while an old canvas still covers a fresh one (right after an
    /// undo): finish the swap now, so the new stroke is visible from its first point.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let overlay = canvasView.superview as? PageOverlayView, overlay.canvas === canvasView,
            overlay.retiredCanvas != nil
        else { return }
        overlay.retireOldCanvas()
    }

    // MARK: Shapes

    /// Where the shape preview ended last, for the shape that is committed on lift.
    private var lastPreviewEnd: CGPoint?

    @objc private func shapeDragged(_ gesture: ShapeDragGesture) {
        guard let overlay = gesture.view as? PageOverlayView else { return }
        switch gesture.state {
        case .began, .changed:
            guard let shape else { return }
            let end = gesture.currentLocation
            lastPreviewEnd = end
            overlay.showShapePreview(
                outline(for: shape, from: gesture.startLocation, to: end), color: color(of: shape), width: CGFloat(shape.width))
        case .ended:
            // The shape is what the preview showed last. The position reported with the lift
            // itself can jump a few points (the Pencil tilts as it leaves the glass), which made
            // the result a slightly different rectangle than the preview (seen on the iPad).
            let end = lastPreviewEnd ?? gesture.currentLocation
            lastPreviewEnd = nil
            if let shape { addShape(shape, from: gesture.startLocation, to: end, on: overlay) } else { overlay.clearShapePreview() }
        default:
            lastPreviewEnd = nil
            overlay.clearShapePreview()
        }
    }

    private func outline(for shape: ShapeSetting, from start: CGPoint, to end: CGPoint) -> ShapeOutline? {
        ShapeGeometry.outline(shape.kind, from: start, to: end, style: shape.lineStyle,
                              width: CGFloat(shape.width), filled: shape.isFilled)
    }

    private func color(of shape: ShapeSetting) -> UIColor { HexColor.color(shape.colorHex) ?? .black }

    /// Puts the shape's strokes into the model as one undo step. The canvas then shows them the
    /// same way as after an undo: the model reports the change and the page gets a fresh canvas
    /// (`modelDrawingChanged`), so PencilKit's old copy of the strokes cannot drop the shape
    /// with the next stroke. Never assign `canvas.drawing` here for that reason.
    /// Points of the drag are the overlay's own coordinates, which are page points (SPEC, M2).
    func addShape(_ shape: ShapeSetting, from start: CGPoint, to end: CGPoint, on overlay: PageOverlayView) {
        guard let outline = outline(for: shape, from: start, to: end) else {
            overlay.clearShapePreview()
            return
        }
        commit(ShapeGeometry.strokes(for: outline, color: color(of: shape), width: CGFloat(shape.width)), on: overlay)
    }

    /// Adds strokes to the page as one undo step ("Shape") and hands the preview over to the ink.
    private func commit(_ strokes: [PKStroke], on overlay: PageOverlayView) {
        var drawing = notebook.drawing(for: overlay.pageID)
        drawing.strokes += strokes
        // A shape only adds ink, so the canvas keeps its strokes and just gets the new drawing; no
        // fresh canvas (swapping made every filled shape on the page flicker, seen on the iPad).
        // `ShapeToolUITests` checks that the next stroke still keeps the shape.
        isSyncing = true
        notebook.setDrawing(drawing, for: overlay.pageID, actionName: "Shape")
        overlay.canvas.drawing = drawing
        isSyncing = false
        overlay.finishShapePreview()
    }

    // MARK: Hold to snap (M7)

    /// A snap in progress: the shape or curve as recognized, where the Pencil was held, and what
    /// the preview showed last (committed on lift, like the shape tool's last end point).
    private struct Snap {
        weak var overlay: PageOverlayView?
        let shape: SnapResult
        let hold: CGPoint
        var current: SnapResult
    }
    private var snap: Snap?

    /// The look of the last stroke drawn with each pen and width (see `InkTemplate`).
    private struct TemplateKey: Hashable {
        let kind: PenKind
        let width: Double
    }
    private var inkTemplates: [TemplateKey: InkTemplate] = [:]

    /// Called by the hold gesture once the Pencil rested: is this stroke a shape, or else a
    /// curve to smooth? Shapes come first, so a held rectangle never becomes a rounded curve.
    func prepareSnap(_ points: [CGPoint], on overlay: PageOverlayView) -> Bool {
        guard snappingPen != nil else { return false }
        let result: SnapResult
        if snapsShapes, let shape = ShapeRecognizer.recognize(points) {
            result = .shape(shape)
        } else if smoothsCurves, let curve = CurveSmoother.smooth(points) {
            result = .curve(curve)
        } else {
            return false
        }
        snap = Snap(overlay: overlay, shape: result, hold: overlay.holdGesture.holdLocation, current: result)
        return true
    }

    @objc private func holdSnapped(_ gesture: HoldToSnapGesture) {
        guard let overlay = gesture.view as? PageOverlayView, var snap, snap.overlay === overlay else { return }
        switch gesture.state {
        case .began:
            // Switching PencilKit's drawing gesture off throws the half stroke away cleanly
            // (SPEC, M2 spike). It stays off until the Pencil is lifted.
            overlay.canvas.drawingGestureRecognizer.isEnabled = false
            showSnapPreview(snap.current, on: overlay)
        case .changed:
            snap.current = snap.shape.following(from: snap.hold, to: gesture.currentLocation)
            self.snap = snap
            showSnapPreview(snap.current, on: overlay)
        case .ended:
            self.snap = nil
            restoreDrawing(on: overlay)
            if let strokes = snapStrokes(snap.current) { commit(strokes, on: overlay) } else { overlay.clearShapePreview() }
        default:
            self.snap = nil
            restoreDrawing(on: overlay)
            overlay.clearShapePreview()
        }
    }

    private func restoreDrawing(on overlay: PageOverlayView) {
        overlay.canvas.drawingGestureRecognizer.isEnabled = !blocksInk
    }

    private func showSnapPreview(_ shape: SnapResult, on overlay: PageOverlayView) {
        guard let pen = snappingPen else { return }
        let color = HexColor.color(pen.setting.colorHex) ?? .black
        // A plain line in roughly the drawn width; textures show once the Pencil is lifted.
        let (alpha, widthFactor): (CGFloat, CGFloat) = switch pen.kind {
        // Alphas matched by eye on the iPad: the highlighter result is stronger, the pencil lighter.
        case .marker: (0.6, 1)
        case .watercolor: (0.5, 0.9)
        case .pencil: (0.5, 0.55)
        case .crayon: (1, 1.3)
        default: (1, 1)
        }
        overlay.showShapePreview(shape.outline, color: color.withAlphaComponent(alpha),
                                 width: CGFloat(pen.setting.width) * widthFactor)
    }

    /// The snapped shape as one stroke in the pen's own ink, looking like the pen's last stroke.
    private func snapStrokes(_ shape: SnapResult) -> [PKStroke]? {
        guard let pen = snappingPen, let points = shape.outline.pieces.first else { return nil }
        let key = TemplateKey(kind: pen.kind, width: pen.setting.width)
        let template = (inkTemplates[key] ?? InkTemplate.fallback(for: pen.kind.inkType, width: CGFloat(pen.setting.width)))
            .drawable(with: pen.kind.inkType, width: CGFloat(pen.setting.width))
        let ink = PKInk(pen.kind.inkType, color: HexColor.color(pen.setting.colorHex) ?? .black)
        return [template.stroke(through: points, ink: ink)]
    }

    /// Remembers the look of a stroke the user just drew with a pen.
    private func rememberInk(of stroke: PKStroke) {
        // A dot or tick (the dot on an i) is not typical of the pen; only real lines count.
        guard let pen = snappingPen, stroke.path.count >= 8, stroke.renderBounds.width + stroke.renderBounds.height >= 15,
            let template = InkTemplate.from(stroke)
        else { return }
        inkTemplates[TemplateKey(kind: pen.kind, width: pen.setting.width)] = template
    }

    // MARK: Canvas → model

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSyncing, let overlay = canvasView.superview as? PageOverlayView else { return }
        isSyncing = true
        defer { isSyncing = false }
        let before = notebook.drawing(for: overlay.pageID).strokes.count
        let drawing = canvasView.drawing
        notebook.setDrawing(drawing, for: overlay.pageID)
        // One new stroke while a pen is selected: the user wrote, remember how it looks.
        if drawing.strokes.count == before + 1, let last = drawing.strokes.last { rememberInk(of: last) }
    }
}
