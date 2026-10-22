import SwiftUI

/// UIViewControllerRepresentable is UIViewRepresentable's bigger sibling: it wraps a whole
/// UIKit view controller. We need one here because showing the tool picker needs a view
/// that is already in a window, which a view controller's `viewDidAppear` tells us.
struct NotebookEditor: UIViewControllerRepresentable {
    let notebook: Notebook

    func makeUIViewController(context: Context) -> NotebookEditorViewController {
        NotebookEditorViewController(notebook: notebook)
    }

    func updateUIViewController(_ controller: NotebookEditorViewController, context: Context) {}
}

/// The editor screen: the notebook with a small toolbar.
struct EditorView: View {
    @Environment(WindowSession.self) private var session
    let notebook: Notebook

    var body: some View {
        NavigationStack {
            NotebookEditor(notebook: notebook)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(notebook.meta.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Library", systemImage: "chevron.backward") { session.close() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { notebook.undoManager.undo() }
                            .disabled(!notebook.canUndo)
                        Button("Redo", systemImage: "arrow.uturn.forward") { notebook.undoManager.redo() }
                            .disabled(!notebook.canRedo)
                    }
                }
        }
    }
}
