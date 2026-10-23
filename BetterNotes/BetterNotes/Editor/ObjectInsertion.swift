import PhotosUI
import SwiftUI

/// Lets SwiftUI views reach the editor's view controller (like a React ref): the toolbar's
/// image menu asks it to insert an image on the page on screen.
final class EditorBridge {
    weak var controller: NotebookEditorViewController?
}

/// Where an image for the page comes from (the toolbar's image menu).
enum ImageSource {
    case photos, files, clipboard
}

extension View {
    /// The Photos and Files pickers for images on a page (M8). `source` opens one of them, or
    /// pastes right away for the clipboard, and is reset afterwards.
    func objectImageInsertion(source: Binding<ImageSource?>, bridge: EditorBridge, report: @escaping (String) -> Void) -> some View {
        modifier(ObjectImageInsertionModifier(source: source, bridge: bridge, report: report))
    }
}

/// `PhotosPicker` shows the system photo library without asking for permission to read all
/// photos: the app only gets the photos the user picks. `fileImporter` is the Files app's picker.
private struct ObjectImageInsertionModifier: ViewModifier {
    @Binding var source: ImageSource?
    let bridge: EditorBridge
    let report: (String) -> Void
    @State private var photoSelection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .onChange(of: source) { _, new in
                guard new == .clipboard else { return }
                source = nil
                bridge.controller?.pasteImage()
            }
            .photosPicker(
                isPresented: Binding(get: { source == .photos }, set: { if !$0 { source = nil } }),
                selection: $photoSelection, maxSelectionCount: 1, matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                guard let item = items.first else { return }
                photoSelection = []
                Task {
                    // The picker hands over a promise; the image data is loaded now.
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        bridge.controller?.insertImage(data: data)
                    } else {
                        report("The photo could not be loaded.")
                    }
                }
            }
            .fileImporter(
                isPresented: Binding(get: { source == .files }, set: { if !$0 { source = nil } }),
                allowedContentTypes: [.image]
            ) { result in
                switch result {
                case .success(let url):
                    // Files from other apps' folders may only be read between these two calls.
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        bridge.controller?.insertImage(data: try Data(contentsOf: url))
                    } catch {
                        report(error.localizedDescription)
                    }
                case .failure(let error):
                    report(error.localizedDescription)
                }
            }
    }
}
