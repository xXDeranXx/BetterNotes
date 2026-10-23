import SwiftUI

/// UIViewControllerRepresentable is UIViewRepresentable's bigger sibling: it wraps a whole
/// UIKit view controller. We need one here because showing the tool picker needs a view
/// that is already in a window, which a view controller's `viewDidAppear` tells us.
struct NotebookEditor: UIViewControllerRepresentable {
    let notebook: Notebook
    let search: DocumentSearch
    let navigator: PageNavigator
    let tools: ToolController
    let bridge: EditorBridge
    var onObjectError: (String) -> Void = { _ in }
    var isToolPickerHidden = false
    var topInset: CGFloat = 0
    /// Where the tab was last time (tabs); the editor goes back there once laid out.
    var position: TabPosition?

    func makeUIViewController(context: Context) -> NotebookEditorViewController {
        let controller = NotebookEditorViewController(notebook: notebook, search: search, navigator: navigator)
        controller.pendingPosition = position
        controller.tools = tools
        controller.onObjectError = onObjectError
        bridge.controller = controller
        controller.onPencilAction = { [tools, weak controller] action, position in
            if tools.perform(action) { controller?.presentPalette(at: position) }
        }
        return controller
    }

    // SwiftUI calls this whenever a value above changes: the way to push state into UIKit.
    func updateUIViewController(_ controller: NotebookEditorViewController, context: Context) {
        controller.setToolPickerHidden(isToolPickerHidden)
        controller.topInset = topInset
        controller.applyTools(tools.settings, isRulerActive: tools.isRulerActive)
    }
}

/// The editor screen: the notebook with a small toolbar.
struct EditorView: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppTheme.settingKey) private var theme = AppTheme.system
    let notebook: Notebook
    /// This editor's own tab: its scroll position is written here, never to
    /// `session.activeTab`, which already points at the next tab while this editor goes away.
    let tab: NotebookTab?
    @State private var search = DocumentSearch()
    @State private var isSearching = false
    @State private var thumbnails: ThumbnailStore
    @State private var navigator: PageNavigator
    @State private var isSidebarVisible = true
    @State private var pageError: String?
    @State private var isShowingGrid = false
    @State private var insertKind: InsertKind?
    @State private var isExporting = false
    /// The window's tools, shared by all tabs.
    private var tools: ToolController { session.tools }
    @State private var bridge = EditorBridge()
    @State private var imageSource: ImageSource?
    @State private var objectError: String?
    /// Size of the editor area, so the toolbar can fit its buttons into it.
    @State private var editorSize: CGSize = .zero
    /// The window's width, for the pen toolbar in the top bar.
    @State private var screenWidth: CGFloat = 0

    init(notebook: Notebook, tab: NotebookTab? = nil) {
        self.notebook = notebook
        self.tab = tab
        _thumbnails = State(initialValue: ThumbnailStore(notebook: notebook))
        _navigator = State(initialValue: PageNavigator(notebook: notebook))
    }

    /// At the top the pen toolbar sits in the top bar itself (like Goodnotes), so nothing floats
    /// over the page; at a side it floats over the page.
    private var isToolbarInBar: Bool {
        tools.settings.toolbarPosition == .top && !tools.settings.usesSystemToolPicker
    }

    /// The middle of the top bar, between the buttons on the left and on the right.
    private var barToolbarLength: CGFloat { max(0, screenWidth - 2 * 120) }

    private var toolbarAlignment: Alignment {
        switch tools.settings.toolbarPosition {
        case .top: .top
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// Top left, unless the pen toolbar sits on the left side.
    private var undoAlignment: Alignment {
        tools.settings.toolbarPosition == .leading && !tools.settings.usesSystemToolPicker ? .topTrailing : .topLeading
    }

    private var actions: PageActions {
        PageActions(notebook: notebook, navigator: navigator, report: { pageError = $0 }, session: session)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    HStack(spacing: 0) {
                        PageSidebar(
                            notebook: notebook, thumbnails: thumbnails, navigator: navigator,
                            actions: actions, insertKind: $insertKind)
                        Divider()
                    }
                    .transition(.move(edge: .leading))  // slides in and out instead of popping
                }
                NotebookEditor(
                    notebook: notebook, search: search, navigator: navigator, tools: tools, bridge: bridge,
                    onObjectError: { objectError = $0 },
                    // The system tool palette floats above full-screen covers (grid, camera).
                    isToolPickerHidden: isShowingGrid || insertKind == .scan,
                    topInset: 0,
                    position: tab?.position)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { editorSize = $0 }
                    // On this inner view, so its pickers do not fight with the page insertion's.
                    .objectImageInsertion(source: $imageSource, bridge: bridge) { objectError = $0 }
                    .overlay(alignment: undoAlignment) {
                        UndoRedoPill(notebook: notebook) { bridge.controller?.finishTextEditing() }
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                    }
                    .overlay(alignment: toolbarAlignment) {
                        if !tools.settings.usesSystemToolPicker && !isToolbarInBar {
                            PenToolbar(tools: tools, onInsertImage: { imageSource = $0 }, availableLength: editorSize.height)
                        }
                    }
            }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
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
                .onAppear {
                    // The session calls this before this tab stops being shown (another tab,
                    // the library, closing), while this editor and its controller still exist.
                    // Captures this editor's own bridge, tab and tools, never "the active tab".
                    session.beforeLeavingTab = { [bridge, tab, tools] in
                        bridge.controller?.finishTextEditing()
                        tools.endTemporaryObjectSelection()
                        if let position = bridge.controller?.currentPosition() { tab?.position = position }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground (home, app switcher, locking): save right away.
                    if phase != .active {
                        bridge.controller?.finishTextEditing()
                        rememberPosition()  // for restoring the tabs after a relaunch
                        BackgroundSave.flush(notebook)
                    }
                }
                // New pages go after the page that is on screen, or at the end.
                .pageInsertion(kind: $insertKind, actions: actions, reveal: true) {
                    guard let current = navigator.currentPageID,
                        let index = notebook.pages.firstIndex(where: { $0.id == current })
                    else { return notebook.pages.count }
                    return index + 1
                }
                .alert("Could not insert the image", isPresented: Binding(
                    get: { objectError != nil }, set: { if !$0 { objectError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(objectError ?? "")
                }
                .alert("Could not change the pages", isPresented: Binding(
                    get: { pageError != nil }, set: { if !$0 { pageError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(pageError ?? "")
                }
                // The grid covers the whole screen. The editor stays alive underneath, so its
                // scroll position and zoom are still there when the grid is closed.
                .fullScreenCover(isPresented: $isShowingGrid) {
                    PageGridView(
                        notebook: notebook, thumbnails: thumbnails, navigator: navigator, actions: actions
                    ) { isShowingGrid = false }
                }
                .sheet(isPresented: $isExporting) {
                    ExportSheet(notebook: notebook, thumbnails: thumbnails) { isExporting = false }
                }
                // The system bar is not used: SwiftUI rebuilt its middle item on every change of the
                // tools, which closed a pen's popover as it opened. The own row (`EditorTopBar`)
                // has the bar's color, so the active tab and the row look like one piece.
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// The row under the tab strip: page buttons, the pen toolbar when it sits at the top,
    /// export and search.
    private var topBar: some View {
        EditorTopBar(theme: theme, scheme: colorScheme) {
            barButton("Pages", "sidebar.left") {
                withAnimation(.easeInOut(duration: 0.25)) { isSidebarVisible.toggle() }
            }
            barButton("Page Grid", "square.grid.2x2") { isShowingGrid = true }
        } middle: {
            if isToolbarInBar {
                PenToolbar(
                    tools: tools, onInsertImage: { imageSource = $0 }, availableLength: barToolbarLength,
                    isInBar: true, barIconColor: theme.primaryText)
            }
        } trailing: {
            if tools.settings.usesSystemToolPicker {
                // The own toolbar is hidden then, so this is the way back to it.
                barButton("Use Own Toolbar", "pencil.tip.crop.circle") { tools.settings.usesSystemToolPicker = false }
            }
            barButton("Export PDF", "square.and.arrow.up") { isExporting = true }
            barButton("Search", "magnifyingglass") {
                if isSearching { search.clear() }
                isSearching.toggle()
            }
        }
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(theme.isTinted ? theme.primaryText : Color.accentColor)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The editor's top row in the theme's bar color (see `AppTheme`): a group of buttons on each
/// side and the pen toolbar in the middle. Plain SwiftUI, so popovers from it stay open.
private struct EditorTopBar<Leading: View, Middle: View, Trailing: View>: View {
    let theme: AppTheme
    let scheme: ColorScheme
    @ViewBuilder let leading: Leading
    @ViewBuilder let middle: Middle
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) { leading }.padding(.horizontal, 4)
            Spacer(minLength: 0)
            middle
            Spacer(minLength: 0)
            HStack(spacing: 0) { trailing }.padding(.horizontal, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(theme.barColor(scheme))
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.12)).frame(height: 0.5) }
    }
}

extension EditorView {
    private func rememberPosition() {
        if let position = bridge.controller?.currentPosition() { tab?.position = position }
    }
}

/// Undo and redo as a small floating pill over the page (like Goodnotes). Typing is finished
/// first, so undo takes back the typing as one step.
private struct UndoRedoPill: View {
    let notebook: Notebook
    let finishTyping: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                finishTyping()
                notebook.undoManager.undo()
            }
            .frame(width: 44, height: 36)
            .disabled(!notebook.canUndo)
            Divider().frame(height: 20)
            Button("Redo", systemImage: "arrow.uturn.forward") {
                finishTyping()
                notebook.undoManager.redo()
            }
            .frame(width: 44, height: 36)
            .disabled(!notebook.canRedo)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(height: 36)
        .padding(.horizontal, 4)
        // Solid, with a shadow: a see-through material vanished on the grey around the page.
        .background(Color(.systemBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
