import SwiftUI

/// UIViewControllerRepresentable is UIViewRepresentable's bigger sibling: it wraps a whole
/// UIKit view controller. We need one here because showing the tool picker needs a view
/// that is already in a window, which a view controller's `viewDidAppear` tells us.
struct NotebookEditor: UIViewControllerRepresentable {
    let notebook: Notebook
    let search: DocumentSearch
    let navigator: PageNavigator

    func makeUIViewController(context: Context) -> NotebookEditorViewController {
        NotebookEditorViewController(notebook: notebook, search: search, navigator: navigator)
    }

    func updateUIViewController(_ controller: NotebookEditorViewController, context: Context) {}
}

/// The editor screen: the notebook with a small toolbar.
struct EditorView: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let notebook: Notebook
    @State private var search = DocumentSearch()
    @State private var isSearching = false
    @State private var thumbnails: ThumbnailStore
    @State private var navigator: PageNavigator
    @State private var isSidebarVisible = true
    @State private var pageError: String?

    init(notebook: Notebook) {
        self.notebook = notebook
        _thumbnails = State(initialValue: ThumbnailStore(notebook: notebook))
        _navigator = State(initialValue: PageNavigator(notebook: notebook))
    }

    private var actions: PageActions {
        PageActions(notebook: notebook, navigator: navigator) { pageError = $0 }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    PageSidebar(notebook: notebook, thumbnails: thumbnails, navigator: navigator, actions: actions)
                    Divider()
                }
                NotebookEditor(notebook: notebook, search: search, navigator: navigator)
            }
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let error = notebook.saveError {
                            SaveErrorBanner(message: error) { Task { await notebook.saveChanges() } }
                        }
                        if isSearching {
                            SearchBar(search: search) {
                                search.clear()
                                isSearching = false
                            }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground (home, app switcher, locking): save right away.
                    if phase != .active { BackgroundSave.flush(notebook) }
                }
                .alert("Could not change the pages", isPresented: Binding(
                    get: { pageError != nil }, set: { if !$0 { pageError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(pageError ?? "")
                }
                .navigationTitle(notebook.meta.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button("Library", systemImage: "chevron.backward") { Task { await session.close() } }
                        Button("Pages", systemImage: "sidebar.left") { isSidebarVisible.toggle() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Add Page", systemImage: "plus.square") { actions.addPageAtEnd() }
                        Button("Search", systemImage: "magnifyingglass") {
                            if isSearching { search.clear() }
                            isSearching.toggle()
                        }
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

/// The search field with the match counter and previous/next buttons.
private struct SearchBar: View {
    let search: DocumentSearch
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        // @Bindable lets us write `$search.query`, a two-way binding into an @Observable
        // object (like `value` + `onChange` on a React input, in one piece).
        @Bindable var search = search
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search in this PDF", text: $search.query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { search.submit() }
                .onChange(of: search.query) { _, text in
                    // Editing the text invalidates the old results.
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.clear() }
                }
            Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button("Previous", systemImage: "chevron.up") { search.previous() }
                .disabled(search.matches.isEmpty)
            Button("Next", systemImage: "chevron.down") { search.next() }
                .disabled(search.matches.isEmpty)
            Button("Done", action: close)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
    }

    private var status: String {
        if search.matches.isEmpty { return search.hasSearched ? "No matches" : "" }
        return "\(search.currentIndex + 1) of \(search.matches.count)"
    }
}
