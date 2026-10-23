import UIKit
import UniformTypeIdentifiers

/// The selected object (M8). Only ids are kept: the object itself is always read from the
/// model, so undo can never leave a stale copy here (SPEC, decision 1).
struct ObjectSelection: Equatable {
    let pageID: UUID
    let objectID: UUID
}

/// Where a finger was held on an empty spot, in page points: Paste puts things there.
struct PasteTarget: Equatable {
    let pageID: UUID
    let point: CGPoint
}

/// What the editor reads from and writes to the clipboard (M8). A copied text box goes there
/// as plain text, for other apps, and as its own type, so pasting it here keeps its font,
/// size, color, bold and italic. Checking what is there (`hasImages`, `hasStrings`, `contains`)
/// does not count as reading, so iPadOS does not ask the user for it.
enum PageClipboard {
    static let textBoxType = "com.betternotes.textbox"

    private struct CopiedTextBox: Codable {
        var width: Double
        var object: PageObject
    }

    static var hasContent: Bool {
        let board = UIPasteboard.general
        return board.hasImages || board.hasStrings || board.contains(pasteboardTypes: [textBoxType])
    }

    static func copy(_ text: TextObject, width: CGFloat) {
        let copied = CopiedTextBox(
            width: Double(width), object: PageObject(frame: CGRect(x: 0, y: 0, width: width, height: 0), content: .text(text)))
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text.text]
        if let data = try? JSONEncoder().encode(copied) { item[textBoxType] = data }
        UIPasteboard.general.setItems([item])
    }

    /// A text box copied in this app, with its width. Only call while pasting (it reads).
    static func copiedTextBox() -> (text: TextObject, width: CGFloat)? {
        guard let data = UIPasteboard.general.data(forPasteboardType: textBoxType),
            let copied = try? JSONDecoder().decode(CopiedTextBox.self, from: data),
            case .text(let text) = copied.object.content
        else { return nil }
        return (text, CGFloat(copied.width))
    }
}

/// A move or resize in progress: what was grabbed, and the object as it was at the start.
struct ObjectDrag {
    let handle: ObjectHandle?
    let original: PageObject
}

/// Selecting, moving, resizing and deleting images and text boxes (M8).
///
/// Touches arrive in the overlay's coordinates, which are page points (SPEC, M2), so
/// `ObjectEditing` works on them directly. Sizes that should look the same at every zoom
/// (handles, how close a touch must be) are screen points divided by the zoom.
extension EditorCoordinator: UIEditMenuInteractionDelegate {
    /// How close to a handle a touch counts as grabbing it, in screen points.
    static let handleReach: CGFloat = 22

    // MARK: Selection

    func selectedObject() -> PageObject? {
        guard let selection else { return nil }
        return notebook.objects(on: selection.pageID).first { $0.id == selection.objectID }
    }

    func select(_ object: PageObject, on overlay: PageOverlayView) {
        if let selection, selection.pageID != overlay.pageID {
            visibleOverlays[selection.pageID]?.showSelection(nil, handles: [], zoom: zoom)
        }
        selection = ObjectSelection(pageID: overlay.pageID, objectID: object.id)
        refreshSelection()
    }

    /// Ends the selection. `notify` tells the editor (it may switch back to the tool used
    /// before a long press); not when the select tool itself was just switched off.
    func clearSelection(notify: Bool) {
        guard let selection else { return }
        self.selection = nil
        objectDrag = nil
        if let overlay = visibleOverlays[selection.pageID] {
            overlay.showSelection(nil, handles: [], zoom: zoom)
            dismissEditMenu(on: overlay)
        }
        if notify { onSelectionCleared?() }
    }

    /// Draws the selection where the model says the object is now (after undo, zoom, a change).
    /// Clears it when the object is gone.
    func refreshSelection() {
        guard selection != nil else { return }
        guard let object = selectedObject() else {
            clearSelection(notify: true)
            return
        }
        showSelection(of: object, at: object.frame)
    }

    private func showSelection(of object: PageObject, at frame: CGRect) {
        guard let selection, let overlay = visibleOverlays[selection.pageID] else { return }
        let handles = ObjectEditing.handles(for: object).map { ObjectEditing.point(of: $0, in: frame) }
        overlay.showSelection(frame, handles: handles, zoom: zoom)
    }

    // MARK: Touches

    /// A touch began on a page while the select tool is on: does it grab a handle or an object?
    /// A touch elsewhere ends the selection and lets the page scroll (finger) or do nothing (Pencil).
    func objectTouchBegan(at point: CGPoint, on overlay: PageOverlayView) -> Bool {
        if let editing = textEditing, editing.pageID == overlay.pageID, let view = editing.view, view.frame.contains(point) {
            return false  // a touch in the box being typed in belongs to the text view
        }
        endTextEditing()
        let objects = notebook.objects(on: overlay.pageID)
        let reach = Self.handleReach / max(zoom, 0.01)
        if let selection, selection.pageID == overlay.pageID,
            let selected = objects.first(where: { $0.id == selection.objectID })
        {
            if let handle = ObjectEditing.handle(at: point, of: selected, radius: reach) {
                objectDrag = ObjectDrag(handle: handle, original: selected)
                return true
            }
            if selected.frame.insetBy(dx: -reach / 3, dy: -reach / 3).contains(point) {
                objectDrag = ObjectDrag(handle: nil, original: selected)
                return true
            }
        }
        if let hit = ObjectEditing.object(at: point, in: objects, slop: reach / 4) {
            select(hit, on: overlay)
            objectDrag = ObjectDrag(handle: nil, original: hit)
            return true
        }
        clearSelection(notify: true)
        return false
    }

    @objc func objectDragged(_ gesture: ObjectDragGesture) {
        guard let overlay = gesture.view as? PageOverlayView, let drag = objectDrag else { return }
        switch gesture.state {
        case .began:
            dismissEditMenu(on: overlay)
        case .changed:
            guard gesture.hasMoved else { return }
            let frame = frame(for: drag, translation: gesture.translation, on: overlay)
            overlay.previewObjectFrame(frame, for: drag.original.id)
            showSelection(of: drag.original, at: frame)
        case .ended:
            objectDrag = nil
            if gesture.hasMoved {
                var object = drag.original
                object.frame = frame(for: drag, translation: gesture.translation, on: overlay)
                notebook.updateObject(object, on: overlay.pageID, actionName: drag.handle == nil ? "Move" : "Resize")
            }
            // A tap (or the end of a drag) shows what can be done with the object.
            presentEditMenu(on: overlay)
        default:
            objectDrag = nil
            showObjects(on: overlay)  // put the view back where the model says
            refreshSelection()
        }
    }

    /// Where the object would be after this drag, in page points.
    private func frame(for drag: ObjectDrag, translation: CGPoint, on overlay: PageOverlayView) -> CGRect {
        let original = drag.original.frame
        guard let handle = drag.handle else {
            return ObjectEditing.moved(original, by: translation, pageSize: overlay.bounds.size)
        }
        if case .text(let text) = drag.original.content {
            var frame = ObjectEditing.resized(original, handle: handle, by: translation, minimumWidth: TextBoxLayout.minimumWidth)
            frame.size.height = TextBoxLayout.height(of: text, width: frame.width)
            return frame
        }
        return ObjectEditing.resized(original, handle: handle, by: translation)
    }

    /// A finger held on an object with another tool: select it (the editor switches to the select
    /// tool). Held on an empty spot with any tool: offer Paste there, if the clipboard has
    /// something a page can take.
    @objc func objectLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let overlay = gesture.view as? PageOverlayView else { return }
        let point = gesture.location(in: overlay)
        if let editing = textEditing, editing.pageID == overlay.pageID, let view = editing.view, view.frame.contains(point) {
            return  // the text view has its own long press (cursor, selection)
        }
        let reach = Self.handleReach / max(zoom, 0.01)
        if let hit = ObjectEditing.object(at: point, in: notebook.objects(on: overlay.pageID), slop: reach / 4) {
            guard !selectsObjects else { return }  // the select tool's drag owns objects
            endTextEditing()
            onLongPressObject?()
            select(hit, on: overlay)
            presentEditMenu(on: overlay)
            return
        }
        guard PageClipboard.hasContent else { return }
        endTextEditing()
        clearSelection(notify: true)
        pasteTarget = PasteTarget(pageID: overlay.pageID, point: point)
        overlay.interactions.compactMap { $0 as? UIEditMenuInteraction }.first?.presentEditMenu(
            with: UIEditMenuConfiguration(identifier: Self.pasteMenuID, sourcePoint: point))
    }

    /// The menu shown on an empty spot (only Paste), told apart from an object's menu by this id.
    static let pasteMenuID = "paste" as NSString

    /// The Paste target, once: the next paste uses it, later ones go to the middle of the screen.
    func takePasteTarget() -> PasteTarget? {
        defer { pasteTarget = nil }
        return pasteTarget
    }

    // MARK: Edit menu

    /// The edit menu is the system's black bubble with Copy, Delete and so on (like the one
    /// over selected text). `UIEditMenuInteraction` shows it; the delegate methods below say
    /// what is in it and where it points.
    func presentEditMenu(on overlay: PageOverlayView) {
        guard let object = selectedObject(), selection?.pageID == overlay.pageID,
            let interaction = overlay.interactions.compactMap({ $0 as? UIEditMenuInteraction }).first
        else { return }
        let point = CGPoint(x: object.frame.midX, y: object.frame.minY)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    private func dismissEditMenu(on overlay: PageOverlayView) {
        overlay.interactions.compactMap { $0 as? UIEditMenuInteraction }.first?.dismissMenu()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if configuration.identifier as? NSString == Self.pasteMenuID {
            return CGRect(origin: configuration.sourcePoint, size: .zero)
        }
        return selectedObject()?.frame ?? .null
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if configuration.identifier as? NSString == Self.pasteMenuID {
            return pasteMenu(from: suggestedActions)
        }
        guard let selection, let object = selectedObject() else { return nil }
        var items: [UIMenuElement] = []
        items += textMenuItems(for: object, selection: selection)
        items += [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyToClipboard(object) },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.duplicate(object, on: selection.pageID)
            },
            UIAction(title: "Bring to Front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
                self?.arrange(object, on: selection.pageID, toFront: true)
            },
            UIAction(title: "Send to Back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { [weak self] _ in
                self?.arrange(object, on: selection.pageID, toFront: false)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.notebook.removeObjects([object.id], from: selection.pageID)
                self?.clearSelection(notify: true)
            },
        ]
        return UIMenu(children: items)
    }

    /// A Paste menu closed without pasting: a later Cmd+V goes to the middle of the screen again.
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard configuration.identifier as? NSString == Self.pasteMenuID else { return }
        animator.addCompletion { [weak self] in self?.pasteTarget = nil }
    }

    /// Only the system's own Paste item. It comes from the responder chain (the editor's root
    /// view answers `canPerformAction(paste:)`), and because the system made it, iPadOS does not
    /// ask "Allow Paste?" when it reads the clipboard, the same as with Cmd+V.
    private func pasteMenu(from suggested: [UIMenuElement]) -> UIMenu? {
        func findPaste(in elements: [UIMenuElement]) -> UIMenuElement? {
            for element in elements {
                if let command = element as? UICommand, command.action == #selector(UIResponderStandardEditActions.paste(_:)) {
                    return command
                }
                if let menu = element as? UIMenu, let found = findPaste(in: menu.children) { return found }
            }
            return nil
        }
        guard let paste = findPaste(in: suggested) else { return nil }
        return UIMenu(children: [paste])
    }

    // MARK: Actions

    private func copyToClipboard(_ object: PageObject) {
        switch object.content {
        case .image(let image):
            guard let data = try? Data(contentsOf: notebook.package.objectFileURL(named: image.file)) else { return }
            let type: UTType = image.file.lowercased().hasSuffix(".png") ? .png : .jpeg
            UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        case .text(let text):
            PageClipboard.copy(text, width: object.frame.width)
        }
    }

    // MARK: Pasting text

    /// Puts a text box on the page, centred on `point` and kept on the page (Paste, Cmd+V).
    /// `width` is the copied box's width; plain text gets the width of its longest line.
    func pasteText(_ text: TextObject, width: CGFloat?, on pageID: UUID, at point: CGPoint, pageSize: CGSize) {
        let width = min(width ?? TextBoxLayout.pastedWidth(of: text, pageWidth: pageSize.width), max(TextBoxLayout.minimumWidth, pageSize.width))
        let height = TextBoxLayout.height(of: text, width: width)
        let x = min(max(point.x - width / 2, 0), max(0, pageSize.width - width))
        let y = min(max(point.y - height / 2, 0), max(0, pageSize.height - height))
        let object = PageObject(frame: CGRect(x: x, y: y, width: width, height: height), content: .text(text))
        notebook.addObject(object, to: pageID, actionName: "Paste")
    }

    /// A text box with the toolbar's font, size, color and style, for pasted plain text.
    func newText(_ string: String) -> TextObject {
        var text = TextObject(text: string, fontSize: textFontSize, colorHex: textColorHex, font: textFont)
        var flags: TextStyleRun.Flags = []
        if textBold { flags.insert(.bold) }
        if textItalic { flags.insert(.italic) }
        if !flags.isEmpty { text.set(flags, everywhere: true) }
        return text
    }

    /// A copy a little below and to the right, selected.
    private func duplicate(_ object: PageObject, on pageID: UUID) {
        guard let overlay = visibleOverlays[pageID] else { return }
        var copy = object.withNewID()
        copy.frame = ObjectEditing.moved(object.frame, by: CGPoint(x: 16, y: 16), pageSize: overlay.bounds.size)
        notebook.addObject(copy, to: pageID, actionName: "Duplicate")
        select(copy, on: overlay)
        presentEditMenu(on: overlay)
    }

    private func arrange(_ object: PageObject, on pageID: UUID, toFront: Bool) {
        var list = notebook.objects(on: pageID).filter { $0.id != object.id }
        if toFront { list.append(object) } else { list.insert(object, at: 0) }
        notebook.setObjects(list, for: pageID, actionName: "Arrange")
    }
}
