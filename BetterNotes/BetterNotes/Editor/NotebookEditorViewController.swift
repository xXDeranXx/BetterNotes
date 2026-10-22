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
final class NotebookEditorViewController: UIViewController {
    private let notebook: Notebook
    private let coordinator: EditorCoordinator
    private let pdfView = PDFView()
    private let search: DocumentSearch
    private var didSetZoomLimits = false

    init(notebook: Notebook, search: DocumentSearch) {
        self.notebook = notebook
        self.search = search
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

        // PDFView re-lays-out by itself when pages are added or removed, but not when a page
        // is turned; asking it to lay out again after every page operation covers both.
        notebook.onStructureChange = { [weak self] in
            self?.pdfView.layoutDocumentView()
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
            coordinator.zoomDidChange(to: pdfView.scaleFactor)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First responder only works once the view is in a window.
        view.becomeFirstResponder()
        coordinator.toolPicker.setVisible(true, forFirstResponder: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinator.toolPicker.setVisible(false, forFirstResponder: view)
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
