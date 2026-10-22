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

    private var zoom: CGFloat = 1
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
        // The model may have changed while this page was off screen (undo), so always
        // load from the model, never trust what the canvas still holds.
        show(notebook.drawing(for: overlay.pageID), in: overlay.canvas)
        toolPicker.addObserver(overlay.canvas)
    }

    func overlayDidDisappear(_ overlay: PageOverlayView) {
        visibleOverlays[overlay.pageID] = nil
        toolPicker.removeObserver(overlay.canvas)
        // SPEC, "Data safety": a changed page is also saved when its canvas leaves the screen.
        // Once that is done, drawings that are saved and off screen are dropped from memory.
        Task { [weak self, notebook] in
            await notebook.saveChanges()
            guard let self else { return }
            notebook.evictDrawings(keeping: Set(visibleOverlays.keys))
        }
    }

    private func show(_ drawing: PKDrawing, in canvas: PKCanvasView) {
        isSyncing = true
        canvas.drawing = drawing
        isSyncing = false
    }

    // MARK: Model → canvas

    private func modelDrawingChanged(_ pageID: UUID) {
        guard !isSyncing, let overlay = visibleOverlays[pageID] else { return }
        show(notebook.drawing(for: pageID), in: overlay.canvas)
    }

    // MARK: Canvas → model

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSyncing, let overlay = canvasView.superview as? PageOverlayView else { return }
        isSyncing = true
        defer { isSyncing = false }
        notebook.setDrawing(canvasView.drawing, for: overlay.pageID)
    }
}
