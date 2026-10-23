import UIKit

/// The text box being typed in: the box as it was when typing began, and whether it is new,
/// so ending the edit knows whether to add, change or remove it.
struct TextEditing {
    let pageID: UUID
    let object: PageObject
    let isNew: Bool
    weak var view: TextBoxEditorView?
}

/// A `UITextView` for typing into a text box on the page. It is laid out like `TextBoxLayout`
/// (same font, padding and line width), so the text does not jump when editing ends.
///
/// Like `PageCanvasView`, it keeps its own undo history: typing must not add steps to the
/// notebook's history one letter at a time (and the notebook groups steps by hand, see
/// `Notebook.undoManager`). Cmd+Z while typing undoes letters; when typing ends, the whole
/// edit becomes one notebook step ("Edit Text").
final class TextBoxEditorView: UITextView {
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }

    init(text: TextObject) {
        super.init(frame: .zero, textContainer: nil)
        let padding = TextBoxLayout.padding
        textContainerInset = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false  // grows with its text instead
        overrideUserInterfaceStyle = .light  // pages are white in dark mode too
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.06)
        layer.borderColor = UIColor.systemBlue.cgColor
        apply(text)
        self.text = text.text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ text: TextObject) {
        font = TextBoxLayout.font(size: text.fontSize)
        textColor = HexColor.color(text.colorHex) ?? .black
        typingAttributes = TextBoxLayout.attributes(for: text)
    }
}

/// Text boxes (M8): place, type, and change size and color.
extension EditorCoordinator: UITextViewDelegate {
    // MARK: Placing and opening

    /// A tap with the text tool: on a text box it opens that box, elsewhere it places a new one.
    @objc func textTapped(_ gesture: PageTapGesture) {
        guard gesture.state == .ended, let overlay = gesture.view as? PageOverlayView else { return }
        let point = gesture.location
        if let editing = textEditing, editing.pageID == overlay.pageID, let view = editing.view, view.frame.contains(point) {
            return  // a tap inside the box being typed in moves the cursor there
        }
        if textEditing != nil {
            endTextEditing()  // a tap outside finishes the box (like Goodnotes)
            return
        }
        let reach = Self.handleReach / max(zoom, 0.01)
        let boxes = notebook.objects(on: overlay.pageID).filter { if case .text = $0.content { true } else { false } }
        if let hit = ObjectEditing.object(at: point, in: boxes, slop: reach / 4) {
            beginTextEditing(hit, isNew: false, on: overlay)
        } else {
            beginTextEditing(newTextBox(at: point, pageSize: overlay.bounds.size), isNew: true, on: overlay)
        }
    }

    /// A new, empty box whose first line is where the tap was, as wide as fits on the page.
    func newTextBox(at point: CGPoint, pageSize: CGSize) -> PageObject {
        let text = TextObject(text: "", fontSize: textFontSize, colorHex: textColorHex)
        let height = TextBoxLayout.height(of: text, width: TextBoxLayout.defaultWidth)
        let x = min(max(point.x - TextBoxLayout.padding, 0), max(0, pageSize.width - TextBoxLayout.minimumWidth))
        let width = max(TextBoxLayout.minimumWidth, min(TextBoxLayout.defaultWidth, pageSize.width - x))
        let y = min(max(point.y - height / 2, 0), max(0, pageSize.height - height))
        return PageObject(frame: CGRect(x: x, y: y, width: width, height: height), content: .text(text))
    }

    /// Opens a text box for typing: a text view takes its place on the page and gets the keyboard.
    func beginTextEditing(_ object: PageObject, isNew: Bool, on overlay: PageOverlayView) {
        guard case .text(let text) = object.content else { return }
        endTextEditing()
        clearSelection(notify: false)
        let view = TextBoxEditorView(text: text)
        view.delegate = self
        view.frame = object.frame
        view.layer.borderWidth = 1 / max(zoom, 0.01)
        overlay.addSubview(view)  // on top of everything, so it gets the touches
        overlay.objectViews[object.id]?.isHidden = true  // the text view shows the text now
        sharpen(view)
        textEditing = TextEditing(pageID: overlay.pageID, object: object, isNew: isNew, view: view)
        view.becomeFirstResponder()
    }

    /// PDFKit enlarges the page from outside, so the text view renders at the ink's resolution.
    private func sharpen(_ view: UIView) {
        let scale = (view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2)
            * Self.renderScale(zoom: zoom, cap: Self.renderScaleCap(for: thermalState))
        view.contentScaleFactor = scale
        view.layer.contentsScale = scale
        for subview in view.subviews { sharpen(subview) }
    }

    // MARK: Typing

    func textViewDidChange(_ textView: UITextView) {
        guard let editing = textEditing, editing.view === textView, case .text(var text) = editing.object.content else { return }
        text.text = textView.text
        textView.frame.size.height = TextBoxLayout.height(of: text, width: textView.frame.width)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard textEditing?.view === textView else { return }
        endTextEditing()
    }

    // MARK: Finishing

    /// Puts what was typed into the model as one undo step and removes the text view. An empty
    /// box is not kept: a new one is simply not added, an existing one is deleted.
    func endTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil  // first: resigning the keyboard calls back into this
        let typed = editing.view?.text ?? ""
        editing.view?.delegate = nil
        editing.view?.resignFirstResponder()
        editing.view?.removeFromSuperview()

        var object = editing.object
        if case .text(var text) = object.content {
            text.text = typed
            object.content = .text(text)
            object.frame.size.height = TextBoxLayout.height(of: text, width: object.frame.width)
        }
        let isEmpty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch (editing.isNew, isEmpty) {
        case (true, true): break
        case (true, false): notebook.addObject(object, to: editing.pageID, actionName: "Add Text")
        case (false, true): notebook.removeObjects([object.id], from: editing.pageID)
        case (false, false): notebook.updateObject(object, on: editing.pageID, actionName: "Edit Text")
        }
        // Show the box again (also when nothing changed, which triggers no model update).
        if let overlay = visibleOverlays[editing.pageID] {
            overlay.objectViews[object.id]?.isHidden = false
            showObjects(on: overlay)
        }
        onTextEditingEnded?()
    }

    /// The text view being typed in (the editor scrolls it above the keyboard).
    var editingTextView: UIView? { textEditing?.view }

    // MARK: Menu entries for a selected text box

    func textMenuItems(for object: PageObject, selection: ObjectSelection) -> [UIMenuElement] {
        guard case .text(let text) = object.content else { return [] }
        let edit = UIAction(title: "Edit Text", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
            guard let self, let overlay = self.visibleOverlays[selection.pageID] else { return }
            self.beginTextEditing(object, isNew: false, on: overlay)
        }
        let sizes = ToolSettings.textFontSizes.map { size in
            UIAction(title: "\(Int(size)) pt", state: size == text.fontSize ? .on : .off) { [weak self] _ in
                self?.changeText(of: object, on: selection.pageID, actionName: "Font Size") { $0.fontSize = size }
            }
        }
        let colors = favoriteColors.map { hex in
            UIAction(
                title: hex, image: UIImage(systemName: "circle.fill")?.withTintColor(HexColor.color(hex) ?? .black, renderingMode: .alwaysOriginal),
                state: hex == text.colorHex ? .on : .off
            ) { [weak self] _ in
                self?.changeText(of: object, on: selection.pageID, actionName: "Text Color") { $0.colorHex = hex }
            }
        }
        return [
            edit,
            UIMenu(title: "Font Size", image: UIImage(systemName: "textformat.size"), children: sizes),
            UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: colors),
        ]
    }

    /// Changes a text box's style as one undo step; its height follows the new size.
    func changeText(of object: PageObject, on pageID: UUID, actionName: String, _ change: (inout TextObject) -> Void) {
        guard case .text(var text) = object.content else { return }
        change(&text)
        var changed = object
        changed.content = .text(text)
        changed.frame.size.height = TextBoxLayout.height(of: text, width: object.frame.width)
        notebook.updateObject(changed, on: pageID, actionName: actionName)
    }
}
