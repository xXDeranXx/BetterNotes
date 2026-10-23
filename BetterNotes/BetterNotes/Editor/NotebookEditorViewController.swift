import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The root view of the editor. It is the long-lived first responder:
/// - the tool picker is shown for it, so the picker stays while canvases come and go;
/// - its `undoManager` is the notebook's, so Cmd+Z and shake to undo reach the model.
final class UndoRoutingView: UIView {
    private let notebook: Notebook

    init(notebook: Notebook) {
        self.notebook = notebook
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { notebook.undoManager }

    /// Paste puts the clipboard's image or text on the page (M8): Cmd+V, and the Paste in the
    /// menu a finger held on an empty spot shows (that menu takes its item from here). Text being
    /// typed handles its own paste (the text view is asked first). PencilKit's lasso has its own
    /// paste for ink, which this does not touch.
    var onPaste: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return onPaste != nil && PageClipboard.hasContent }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        onPaste?()
    }
}

/// Where a scroll view was: its zoom and offset. Two snapshots tell whether it moved.
struct ScrollSnapshot: Equatable {
    var zoom: CGFloat
    var offset: CGPoint

    init(zoom: CGFloat, offset: CGPoint) {
        self.zoom = zoom
        self.offset = offset
    }

    init(_ scrollView: UIScrollView) {
        self.init(zoom: scrollView.zoomScale, offset: scrollView.contentOffset)
    }

    /// Still: zoom changed by less than 1 % and the offset by less than 4 points.
    func isStill(comparedTo now: ScrollSnapshot) -> Bool {
        abs(now.zoom - zoom) < 0.01 * max(zoom, 0.01) && hypot(now.offset.x - offset.x, now.offset.y - offset.y) < 4
    }
}

/// Shows a notebook's PDF with a canvas over every visible page, or a whiteboard: one overlay
/// in board mode that fills the editor (its canvas scrolls and zooms the board itself).
final class NotebookEditorViewController: UIViewController, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let notebook: Notebook
    private let coordinator: EditorCoordinator
    /// For tests: which page canvases the editor holds.
    var coordinatorForTests: EditorCoordinator { coordinator }
    private let pdfView = PDFView()
    /// The whiteboard's overlay; nil for a notebook.
    private var board: PageOverlayView?
    private let search: DocumentSearch
    private let navigator: PageNavigator
    private var didSetZoomLimits = false
    private var isToolPickerHidden = false
    private var toolSettings = ToolSettings()
    var tools: ToolController?
    /// Where the Pencil hovered last, for when the squeeze itself carries no position.
    private var lastHover: CGPoint?
    /// The editor view forwards the Pencil's squeeze and double tap to the toolbar.
    var onPencilAction: ((UIPencilPreferredAction, CGPoint?) -> Void)?
    /// The "fit to width" zoom the last time the pages were laid out. It changes when a page
    /// operation changes the widest page (turning a page sideways), see `refitIfPagesChangedWidth`.
    private var lastFitScale: CGFloat = 0

    /// Room above the first page for the pen toolbar when it floats at the top, so it does not
    /// cover the top of the page. Pages still scroll up under the toolbar.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { applyTopInset() } }
    }

    /// The `@AppStorage` key of the scroll direction, the same in every window.
    static let scrollsHorizontallyKey = "scrollsPagesHorizontally"

    /// Pages side by side, one at a time, turned with a finger swipe (an app-wide setting).
    /// Otherwise one long vertical column. Ignored on a whiteboard.
    var scrollsHorizontally = false {
        didSet {
            guard scrollsHorizontally != isPageByPage, board == nil, pdfView.document != nil else { return }
            switchDisplayMode()
        }
    }

    /// The mode PDFView actually shows (follows `scrollsHorizontally` once the view exists).
    private var isPageByPage = false

    /// The page on screen in page-by-page mode, by id and by place: after a page operation the
    /// view goes back to it, or to the page now at its place if it was deleted.
    private var shownPageID: UUID?
    private var shownPageIndex = 0

    /// PDFView scrolls with a scroll view of its own: in vertical mode its direct subview, in
    /// page-by-page mode one per page (the shown page's zooms and scrolls that page).
    private var pdfScrollView: UIScrollView? {
        guard board == nil else { return nil }
        if isPageByPage {
            guard let id = shownPageID, let overlay = coordinator.visibleOverlays[id] else { return nil }
            var ancestor = overlay.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            return ancestor as? UIScrollView
        }
        return pdfView.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }

    /// What scrolls the content: PDFView's scroll view, or the whiteboard's canvas.
    private var contentScrollView: UIScrollView? { board?.canvas ?? pdfScrollView }

    private func applyTopInset() {
        // Page by page, PDFKit centers each page itself.
        guard !isPageByPage, let scrollView = pdfScrollView, scrollView.contentInset.top != topInset else { return }
        // At the very top (where a notebook opens), stay at the top so the first page moves down.
        let wasAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
        scrollView.contentInset.top = topInset
        if wasAtTop { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
    }

    init(notebook: Notebook, search: DocumentSearch, navigator: PageNavigator) {
        self.notebook = notebook
        self.search = search
        self.navigator = navigator
        self.coordinator = EditorCoordinator(notebook: notebook)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let routing = UndoRoutingView(notebook: notebook)
        routing.onPaste = { [weak self] in self?.paste() }
        view = routing
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // SPEC, "File format": the page list and the PDF must agree. If not, do not guess.
        // The model checked that when it opened; it shares its document with this view, so a
        // page operation on the model shows up here without further work.
        guard let document = notebook.document else {
            showProblem(notebook.structureProblem ?? "This notebook cannot be opened.")
            return
        }

        installGestures()
        // A long press on an object switches to the select tool until nothing is selected.
        coordinator.onLongPressObject = { [weak self] in self?.tools?.beginTemporaryObjectSelection() }
        coordinator.onSelectionCleared = { [weak self] in self?.tools?.endTemporaryObjectSelection() }
        // The text view had the keyboard focus; give it back to the editor (Cmd+Z, tool picker).
        coordinator.onTextEditingEnded = { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.view.becomeFirstResponder()
        }
        // Text being typed is put into the model before the app leaves the screen, so the
        // save on the way to the background includes it.
        NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) {
            [weak self] note in
            // Compared by identity only (the scene object itself stays on its own thread).
            let scene = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, scene == self.view.window?.windowScene.map(ObjectIdentifier.init) else { return }  // only this window
                self.finishTextEditing()
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) {
            [weak self] note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.keepTextAboveKeyboard(keyboardFrame: frame) }
        }

        if notebook.meta.isWhiteboard, let page = notebook.pages.first {
            let overlay = coordinator.makeOverlay(pageID: page.id, boardSize: CGSize(width: page.size.width, height: page.size.height))
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(overlay)
            board = overlay
            return  // shown once it has its size (viewDidLayoutSubviews)
        }

        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.backgroundColor = .systemGray5
        applyDisplayMode()
        pdfView.maxScaleFactor = 6
        // Without markup mode PDFView's text selection can swallow Pencil input on PDFs with text.
        pdfView.isInMarkupMode = true
        // The provider must be set before the document, so the first pages get their overlays.
        pdfView.pageOverlayViewProvider = coordinator
        pdfView.document = document
        view.addSubview(pdfView)
        search.pdfView = pdfView
        navigator.attach(pdfView)

        // PDFView re-lays-out by itself when pages are added or removed, but not when a page
        // is turned; asking it to lay out again after every page operation covers both.
        notebook.onStructureChange = { [weak self] in
            guard let self else { return }
            if self.isPageByPage {
                self.reloadPagesAfterStructureChange()
                return
            }
            self.pdfView.layoutDocumentView()
            self.refitIfPagesChangedWidth()
            // PDFView finishes laying out a moment later; look again then.
            DispatchQueue.main.async { [weak self] in self?.refitIfPagesChangedWidth() }
        }

        // Keep ink sharp: tell the coordinator about every zoom change (see EditorCoordinator).
        NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coordinator.zoomDidChange(to: self.pdfView.scaleFactor)
            }
        }
        // Page-by-page: each page opens at its own fit, so the zoom changes with the page.
        NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageDidChange() }
        }
        pageDidChange()
    }

    // MARK: Page by page

    /// Sets PDFView's layout for `scrollsHorizontally`. PDFKit's page-by-page mode is a page
    /// view controller (like a book app): one page at a time, a finger swipe turns it, and every
    /// page has its own zoom, starting at "whole page visible".
    private func applyDisplayMode() {
        isPageByPage = scrollsHorizontally
        if isPageByPage {
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(true)
        } else {
            if pdfView.isUsingPageViewController { pdfView.usePageViewController(false) }
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        pdfView.minScaleFactor = 0.1  // the old mode's limit must not stop the new fit
        fitAgain()
    }

    /// Switching `autoScales` off and on again makes PDFView fit the pages again.
    private func fitAgain() {
        pdfView.autoScales = false
        pdfView.autoScales = true
    }

    /// The smallest zoom: half the fit in the vertical column (to see more pages), the fit
    /// itself page by page (smaller would only show grey around one page).
    private func applyZoomLimits() {
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        pdfView.minScaleFactor = isPageByPage ? fit : fit * 0.5
        lastFitScale = fit
    }

    private func pageDidChange() {
        guard isPageByPage, let page = pdfView.currentPage, let id = notebook.pageID(for: page) else { return }
        shownPageID = id
        shownPageIndex = notebook.pages.firstIndex(where: { $0.id == id }) ?? shownPageIndex
        if didSetZoomLimits { applyZoomLimits() }
        restrictPageTurnsToFingers()
        coordinator.zoomDidChange(to: pdfView.scaleFactor)
    }

    /// The page view controller's swipe would also take the Pencil; the Pencil writes, only
    /// fingers (and a trackpad) turn pages. Its scroll view is the one that pages.
    private func restrictPageTurnsToFingers() {
        var queue: [UIView] = [pdfView]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView, scrollView.isPagingEnabled {
                scrollView.panGestureRecognizer.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer]
                    .map { NSNumber(value: $0.rawValue) }
                return
            }
            queue.append(contentsOf: view.subviews)
        }
    }

    /// The page on screen now: page by page the shown one, else the one at the top.
    private var pageOnScreen: UUID? {
        if isPageByPage { return shownPageID }
        // PDFView's current page, not the one at the top-left corner: that corner is often in
        // the gap above a page, which counts as the page before.
        return pdfView.currentPage.flatMap { notebook.pageID(for: $0) }
    }

    /// Shows `pageID` (or the first page) from a fresh start of PDFView's layout. Page by page,
    /// PDFKit keeps showing the page it had even when that page was deleted or moved, and then
    /// `go(to:)` does nothing (it thinks it is already there); setting the document again is
    /// the reliable way to refresh. PDFKit does not report the overlays it drops then, so they
    /// are let go here first (which also saves their pages).
    private func reloadPages(showing pageID: UUID?, beforeReload: () -> Void = {}) {
        guard let document = notebook.document else { return }
        finishTextEditing()
        coordinator.visibleOverlays.values.forEach(coordinator.overlayDidDisappear)
        pdfView.document = nil
        beforeReload()
        pdfView.document = document
        let index = pageID.flatMap { id in notebook.pages.firstIndex(where: { $0.id == id }) } ?? 0
        if let page = document.page(at: index) { pdfView.go(to: page) }
        pdfView.layoutIfNeeded()
        if didSetZoomLimits { applyZoomLimits() }
        if isPageByPage {
            pageDidChange()
        } else {
            coordinator.zoomDidChange(to: pdfView.scaleFactor)
        }
    }

    /// After a page operation page by page: back to the page that was shown, or, if it was
    /// deleted, to the page that took its place (the one after it, or the new last page).
    private func reloadPagesAfterStructureChange() {
        let pages = notebook.pages
        let target = shownPageID.flatMap { id in pages.contains(where: { $0.id == id }) ? id : nil }
            ?? (pages.isEmpty ? nil : pages[min(shownPageIndex, pages.count - 1)].id)
        // A new page view controller as well: the old one reuses its view of the first page
        // and never asks for a canvas for it again.
        reloadPages(showing: target) {
            pdfView.usePageViewController(false)
            pdfView.usePageViewController(true)
        }
    }

    /// Vertical <-> page by page, staying on the same page.
    private func switchDisplayMode() {
        reloadPages(showing: pageOnScreen) { applyDisplayMode() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let board {
            guard !didSetZoomLimits, board.bounds.width > 0 else { return }
            didSetZoomLimits = true
            board.layoutIfNeeded()
            // Size and zoom first, then the drawing (SPEC, M2 lesson): place the board, then
            // let the coordinator give the canvas its ink.
            if let position = pendingPosition {
                pendingPosition = nil
                board.showBoard(at: position.point, zoom: position.zoom)
            } else {
                board.showBoardCenter()
            }
            coordinator.zoomDidChange(to: board.canvas.zoomScale)
            coordinator.overlayDidAppear(board)
            return
        }
        applyTopInset()  // PDFView may reset its scroll view's inset when it lays out
        if !didSetZoomLimits, pdfView.document != nil, pdfView.scaleFactorForSizeToFit > 0 {
            didSetZoomLimits = true
            // Page by page, PDFKit fitted the page to the size the view had before it was
            // laid out, and does not fit again by itself.
            if isPageByPage { fitAgain() }
            applyZoomLimits()
            coordinator.zoomDidChange(to: pdfView.scaleFactor)
            // PDFView and the toolbar inset settle a moment later; then go back to the old spot.
            if pendingPosition != nil {
                DispatchQueue.main.async { [weak self] in self?.restorePendingPosition() }
            }
        } else if isPageByPage, didSetZoomLimits, abs(pdfView.scaleFactorForSizeToFit - lastFitScale) > 0.001 {
            // The window changed size (turned, Split View): fit the whole page again.
            fitAgain()
            applyZoomLimits()
            coordinator.zoomDidChange(to: pdfView.scaleFactor)
        }
    }

    /// PDFView only fits the pages to the width when the document or the view size changes.
    /// After a page was turned sideways the widest page is wider, and without this it would run
    /// off the screen. Operations that do not change the widest page (adding a page) keep the
    /// zoom the user chose.
    private func refitIfPagesChangedWidth() {
        let fit = pdfView.scaleFactorForSizeToFit
        guard didSetZoomLimits, fit > 0, abs(fit - lastFitScale) > 0.001 else { return }
        applyZoomLimits()
        pdfView.autoScales = false  // switching it off and on again makes PDFView fit again
        pdfView.autoScales = true
        coordinator.zoomDidChange(to: pdfView.scaleFactor)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First responder only works once the view is in a window.
        view.becomeFirstResponder()
        coordinator.toolPicker.setVisible(showsSystemToolPicker, forFirstResponder: view)
    }

    /// The tool palette floats above everything in the window, also above a full-screen page
    /// grid that covers this editor, so the grid asks for it to be hidden while it is open.
    func setToolPickerHidden(_ hidden: Bool) {
        guard hidden != isToolPickerHidden else { return }
        isToolPickerHidden = hidden
        updateToolPickerVisibility()
    }

    /// The system picker is only shown when the user chose it in the toolbar settings; the own
    /// toolbar is SwiftUI and lives in `EditorView`.
    private var showsSystemToolPicker: Bool { !isToolPickerHidden && coordinator.usesSystemToolPicker }

    private func updateToolPickerVisibility() {
        guard view.window != nil else { return }  // viewDidAppear applies it later
        if showsSystemToolPicker { view.becomeFirstResponder() }
        coordinator.toolPicker.setVisible(showsSystemToolPicker, forFirstResponder: view)
    }

    func applyTools(_ settings: ToolSettings, isRulerActive: Bool) {
        toolSettings = settings
        coordinator.apply(settings: settings, isRulerActive: isRulerActive)
        updateToolPickerVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishTextEditing()
        coordinator.toolPicker.setVisible(false, forFirstResponder: view)
    }

    // MARK: Gestures and the Pencil

    /// Two-finger tap = undo, three-finger tap = redo (configurable), like Goodnotes. The Pencil's
    /// squeeze and double tap are delivered by `UIPencilInteraction`; without the system tool
    /// picker the app has to handle them itself.
    private func installGestures() {
        for (touches, action) in [(2, #selector(undoTapped)), (3, #selector(redoTapped))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.numberOfTouchesRequired = touches
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]  // fingers only
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            undoRedoTaps.append(tap)
        }
        view.addInteraction(UIPencilInteraction(delegate: self))
        // Tracks the hovering Pencil (iPads that support hover) so the palette can open at its tip.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.delegate = self
        view.addGestureRecognizer(hover)
    }

    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        lastHover = hover.state == .ended || hover.state == .cancelled ? lastHover : hover.location(in: view)
    }

    /// Opens the pen's color and width as a popover at the Pencil, to the right of it for
    /// left-handed writers (so the hand does not cover it) and to the left otherwise.
    func presentPalette(at position: CGPoint?) {
        guard let tools, presentedViewController == nil else { return }
        let anchor = position ?? lastHover ?? CGPoint(x: view.bounds.midX, y: 80)
        let content = UIHostingController(rootView: QuickPaletteView(tools: tools))
        content.modalPresentationStyle = .popover
        content.preferredContentSize = content.sizeThatFits(in: CGSize(width: 320, height: 700))
        if let popover = content.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(origin: anchor, size: CGSize(width: 1, height: 1))
            popover.permittedArrowDirections = toolSettings.isLeftHanded ? .left : .right
        }
        present(content, animated: true)
    }

    /// Puts the text box being typed in into the model, and saves if that changed anything.
    /// Called before anything that saves, closes or undoes, so typed text is never lost or
    /// added after the last save.
    func finishTextEditing() {
        guard coordinator.editingTextView != nil else { return }
        coordinator.endTextEditing()
        if notebook.hasUnsavedChanges { BackgroundSave.flush(notebook) }
    }

    @objc private func undoTapped() {
        finishTextEditing()  // undo then takes back the typing as one step
        if toolSettings.twoFingerTapUndoes, notebook.undoManager.canUndo { notebook.undoManager.undo() }
    }

    @objc private func redoTapped() {
        finishTextEditing()
        if toolSettings.threeFingerTapRedoes, notebook.undoManager.canRedo { notebook.undoManager.redo() }
    }

    // The taps must not stop scrolling and zooming, which also use two fingers.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// The two- and three-finger taps, and where the content was when their first finger came
    /// down. A short pinch can look like a two-finger tap; on the iPad zooming a whiteboard
    /// sometimes undid a stroke. A tap only counts if nothing scrolled or zoomed meanwhile.
    private var undoRedoTaps: [UITapGestureRecognizer] = []
    private var scrollAtTapStart: ScrollSnapshot?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if undoRedoTaps.contains(where: { $0 === gestureRecognizer }), gestureRecognizer.numberOfTouches == 0 {
            scrollAtTapStart = contentScrollView.map(ScrollSnapshot.init)
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard undoRedoTaps.contains(where: { $0 === gestureRecognizer }), let scrollView = contentScrollView else { return true }
        return !scrollView.isZooming && !scrollView.isZoomBouncing
            && (scrollAtTapStart?.isStill(comparedTo: ScrollSnapshot(scrollView)) ?? true)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencilAction?(UIPencilInteraction.preferredTapAction, tap.hoverPose.map { $0.location })
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended {
            onPencilAction?(UIPencilInteraction.preferredSqueezeAction, squeeze.hoverPose.map { $0.location })
        }
    }

    /// Scrolls the page up when the on-screen keyboard would cover the text box being typed in.
    private func keepTextAboveKeyboard(keyboardFrame: CGRect?) {
        guard let keyboardFrame, let textView = coordinator.editingTextView, let window = view.window,
            let scrollView = contentScrollView
        else { return }
        let box = textView.convert(textView.bounds, to: window)
        let overlap = box.maxY + 24 - keyboardFrame.minY
        guard overlap > 0 else { return }
        var offset = scrollView.contentOffset
        offset.y += overlap
        scrollView.setContentOffset(offset, animated: true)
    }

    // MARK: Inserting images (M8)

    /// Tells the editor screen that an image could not be inserted.
    var onObjectError: ((String) -> Void)?

    // MARK: Position (tabs)

    /// Where the tab was when it was last shown; applied once, after the first layout.
    var pendingPosition: TabPosition?

    /// The page at the top left of the visible area (below the toolbar), that point on it and
    /// the zoom, so coming back to the tab shows the same spot.
    func currentPosition() -> TabPosition? {
        guard didSetZoomLimits else { return pendingPosition }  // not laid out yet: keep the old one
        if let board {
            // The board point at the top-left corner, in page points, and the zoom.
            return TabPosition(pageID: board.pageID, point: board.visibleBoardRect.origin, zoom: board.canvas.zoomScale)
        }
        if isPageByPage {
            // The whole page is the spot; zoom 0 means "fit" (also in the vertical column).
            return shownPageID.map { TabPosition(pageID: $0, point: .zero, zoom: 0) }
        }
        let topLeft = CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY + topInset)
        guard let page = pdfView.page(for: topLeft, nearest: true), let id = notebook.pageID(for: page) else { return nil }
        return TabPosition(pageID: id, point: pdfView.convert(topLeft, to: page), zoom: pdfView.scaleFactor)
    }

    private func restorePendingPosition() {
        guard let position = pendingPosition else { return }
        pendingPosition = nil
        guard let index = notebook.pages.firstIndex(where: { $0.id == position.pageID }),
            let page = notebook.document?.page(at: index)
        else { return }  // the page was deleted meanwhile: stay at the top
        if isPageByPage || position.zoom <= 0 {
            // Page by page each page opens at its fit; a spot saved page by page (zoom 0) is
            // the top of its page at the fit in the vertical column.
            if !isPageByPage { fitAgain() }
            pdfView.go(to: page)
            coordinator.zoomDidChange(to: pdfView.scaleFactor)
            coordinator.reloadVisibleCanvases()
            return
        }
        if abs(position.zoom - pdfView.scaleFactor) > 0.001 {
            pdfView.scaleFactor = min(max(position.zoom, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        }
        // The destination's point ends up at the top of the view, which is under the toolbar.
        pdfView.go(to: PDFDestination(page: page, at: position.point))
        if let scrollView = pdfScrollView, topInset > 0 {
            scrollView.contentOffset.y = max(scrollView.contentOffset.y - topInset, -scrollView.adjustedContentInset.top)
        }
        coordinator.zoomDidChange(to: pdfView.scaleFactor)
        coordinator.reloadVisibleCanvases()
    }

    /// The page in the middle of the visible area (below the toolbar) and that point on it,
    /// in page coordinates. New images go there.
    func pageAtScreenCenter() -> (id: UUID, point: CGPoint)? {
        if let board {
            let visible = board.visibleBoardRect
            return (board.pageID, CGPoint(x: visible.midX, y: visible.midY))
        }
        let visible = pdfView.bounds.inset(by: UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0))
        let center = CGPoint(x: visible.midX, y: visible.midY)
        guard let page = pdfView.page(for: center, nearest: true), let id = notebook.pageID(for: page) else { return nil }
        let box = page.bounds(for: .cropBox)
        let geometry = PageGeometry(size: box.size, boxOrigin: box.origin)
        return (id, geometry.pagePoint(fromPDF: pdfView.convert(center, to: page)))
    }

    /// Image bytes from Photos or Files: shrunk in the background, then put on the page on screen.
    func insertImage(data: Data) {
        insertPrepared(at: nil) { try ObjectImageImport.prepare(data) }
    }

    /// The clipboard's content where a finger was held (the Paste menu), or in the middle of the
    /// screen (Cmd+V): a text box copied here, else an image, else text as a new text box.
    func paste() {
        let target = coordinator.takePasteTarget().map { (id: $0.pageID, point: $0.point) }
        let board = UIPasteboard.general
        if let copied = PageClipboard.copiedTextBox() {
            pasteText(copied.text, width: copied.width, at: target)
        } else if board.hasImages {
            pasteImage(at: target)
        } else if let string = board.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pasteText(coordinator.newText(string), width: nil, at: target)
        } else {
            onObjectError?("There is nothing on the clipboard that can go on a page. Copy an image or some text first.")
        }
    }

    private func pasteText(_ text: TextObject, width: CGFloat?, at target: (id: UUID, point: CGPoint)?) {
        guard let target = target ?? pageAtScreenCenter(),
            let pageSize = coordinator.visibleOverlays[target.id]?.pageSize
        else { return }
        coordinator.pasteText(text, width: width, on: target.id, at: target.point, pageSize: pageSize)
    }

    /// The clipboard's image. Reading its bytes keeps a PNG screenshot a PNG; a picture that
    /// only exists as a `UIImage` is stored as JPEG unless it has transparency.
    func pasteImage(at target: (id: UUID, point: CGPoint)? = nil) {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else {
            onObjectError?("There is no image on the clipboard. Copy an image first, for example a screenshot or a photo.")
            return
        }
        for type in [UTType.png, .jpeg, .heic] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) {
                insertPrepared(at: target) { try ObjectImageImport.prepare(data) }
                return
            }
        }
        guard let image = pasteboard.image else {
            onObjectError?("The clipboard's image could not be read.")
            return
        }
        insertPrepared(at: target) { try ObjectImageImport.prepare(image) }
    }

    /// `target` is where the image goes; nil means the middle of the screen when it is ready.
    private func insertPrepared(
        at target: (id: UUID, point: CGPoint)?, _ prepare: @escaping @Sendable () throws -> ObjectImageImport.Prepared
    ) {
        Task {
            do {
                // Shrinking a 12-megapixel photo takes a moment; not on the main thread.
                let prepared = try await Task.detached(priority: .userInitiated) { try prepare() }.value
                guard let target = target ?? pageAtScreenCenter() else { return }
                try notebook.insertImage(prepared, on: target.id, center: target.point, area: board?.visibleBoardRect.size)
            } catch {
                onObjectError?(error.localizedDescription)
            }
        }
    }

    private func showProblem(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])
    }
}
