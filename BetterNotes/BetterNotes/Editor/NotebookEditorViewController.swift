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
    private var didSetZoomLimits = false

    init(notebook: Notebook) {
        self.notebook = notebook
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
        guard let document = PDFDocument(url: notebook.package.pdfURL),
            document.pageCount == notebook.pages.count
        else {
            showProblem("This notebook cannot be opened: its page list and its PDF do not match. Nothing was changed.")
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didSetZoomLimits, pdfView.document != nil, pdfView.scaleFactorForSizeToFit > 0 {
            didSetZoomLimits = true
            pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
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
