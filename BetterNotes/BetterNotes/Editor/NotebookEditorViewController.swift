import PDFKit
import PencilKit
import UIKit

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
}

/// Shows a notebook's PDF with a canvas over every visible page.
final class NotebookEditorViewController: UIViewController, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let notebook: Notebook
    private let coordinator: EditorCoordinator
    private let pdfView = PDFView()
    private let search: DocumentSearch
    private let navigator: PageNavigator
    private var didSetZoomLimits = false
    private var isToolPickerHidden = false
    private var tools = ToolSettings()
    /// The editor view forwards the Pencil's squeeze and double tap to the toolbar.
    var onPencilAction: ((UIPencilPreferredAction) -> Void)?
    /// The "fit to width" zoom the last time the pages were laid out. It changes when a page
    /// operation changes the widest page (turning a page sideways), see `refitIfPagesChangedWidth`.
    private var lastFitScale: CGFloat = 0

    init(notebook: Notebook, search: DocumentSearch, navigator: PageNavigator) {
        self.notebook = notebook
        self.search = search
        self.navigator = navigator
        self.coordinator = EditorCoordinator(notebook: notebook)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = UndoRoutingView(notebook: notebook)
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

        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.backgroundColor = .systemGray5
        pdfView.displayMode = .singlePageContinuous  // vertical continuous scrolling
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didSetZoomLimits, pdfView.document != nil, pdfView.scaleFactorForSizeToFit > 0 {
            didSetZoomLimits = true
            pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
            lastFitScale = pdfView.scaleFactorForSizeToFit
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
        lastFitScale = fit
        pdfView.minScaleFactor = fit * 0.5
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
        tools = settings
        coordinator.apply(settings: settings, isRulerActive: isRulerActive)
        updateToolPickerVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        }
        view.addInteraction(UIPencilInteraction(delegate: self))
    }

    @objc private func undoTapped() {
        if tools.twoFingerTapUndoes, notebook.undoManager.canUndo { notebook.undoManager.undo() }
    }

    @objc private func redoTapped() {
        if tools.threeFingerTapRedoes, notebook.undoManager.canRedo { notebook.undoManager.redo() }
    }

    // The taps must not stop scrolling and zooming, which also use two fingers.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencilAction?(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { onPencilAction?(UIPencilInteraction.preferredSqueezeAction) }
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
