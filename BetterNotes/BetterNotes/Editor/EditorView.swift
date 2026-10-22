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
    @Environment(\.scenePhase) private var scenePhase
    let notebook: Notebook

    var body: some View {
        NavigationStack {
            NotebookEditor(notebook: notebook)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = notebook.saveError {
                        SaveErrorBanner(message: error) { Task { await notebook.saveChanges() } }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground (home, app switcher, locking): save right away.
                    if phase != .active { BackgroundSave.flush(notebook) }
                }
                .navigationTitle(notebook.meta.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Library", systemImage: "chevron.backward") { Task { await session.close() } }
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

/// Shown when saving failed. The notebook stays open and in memory, so nothing is lost
/// while the problem (usually a full iPad) is fixed; Retry saves again.
private struct SaveErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Your latest changes are not saved yet: \(message)")
                .font(.callout)
            Spacer()
            Button("Retry", action: retry).buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
    }
}
