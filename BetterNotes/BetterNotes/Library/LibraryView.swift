import SwiftUI
import UniformTypeIdentifiers

/// The library, styled after Goodnotes: a sidebar (Documents, Favorites, Recents, Trash) and a
/// grid of folder and notebook tiles. Tap a folder to open it, tap a notebook to write in it.
struct LibraryView: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    // @State is like React's useState: SwiftUI owns the value and re-runs `body` whenever
    // it changes. For an @Observable class like LibraryModel it keeps one instance per view.
    @State private var model = LibraryModel()
    @State private var isPickingPDF = false
    @State private var isDropTargeted = false
    @State private var isCreatingNotebook = false
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var itemToMove: URL?
    @State private var itemToTrash: (url: URL, name: String)?
    @State private var dropTargetFolder: URL?
    @State private var isConfirmingEmptyTrash = false
    @State private var isTrashDropTargeted = false

    private enum NamePrompt: Identifiable {
        case newFolder
        case rename(URL, String)
        var id: String {
            switch self {
            case .newFolder: "new"
            case .rename(let url, _): url.path
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(model.title)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { toolbar }
            }
        }
        // Drag and drop from another app in Split View, also on the navigation bar.
        .pdfDropTarget(isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 4)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // The system's Files picker. It hands back URLs we may read for a short while.
        .fileImporter(
            isPresented: $isPickingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await session.importPDFs(urls); await model.reload() }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isCreatingNotebook) {
            NewNotebookSheet(
                create: { title, template, size, color in
                    isCreatingNotebook = false
                    Task {
                        guard let package = await model.createNotebook(
                            title: title, template: template, size: size, coverColor: color)
                        else { return }
                        open(NotebookSummary.placeholder(for: package))
                    }
                },
                cancel: { isCreatingNotebook = false })
        }
        .sheet(item: Binding(get: { itemToMove.map(MoveRequest.init) }, set: { itemToMove = $0?.url })) { request in
            FolderPickerSheet(
                item: request.url, root: model.location.root, folders: model.allFolders,
                choose: { destination in
                    itemToMove = nil
                    Task { await model.move(request.url, into: destination) }
                },
                cancel: { itemToMove = nil })
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(promptButton) { commitPrompt() }
        }
        .confirmationDialog(
            "Move \"\(itemToTrash?.name ?? "")\" to the trash?",
            isPresented: Binding(get: { itemToTrash != nil }, set: { if !$0 { itemToTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let url = itemToTrash?.url { Task { await model.trash(url) } }
            }
        } message: {
            Text("You can put it back from the Trash for 30 days.")
        }
        .confirmationDialog("Delete everything in the trash permanently?", isPresented: $isConfirmingEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            await model.reload()
            await model.purgeExpiredTrash()
        }
        // Files can move in the Files app while we are in the background (SPEC, "Data safety").
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
    }

    private struct MoveRequest: Identifiable {
        let url: URL
        var id: URL { url }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { section in
            if let section { Task { await model.select(section) } }
        })) {
            Section {
                Label("Documents", systemImage: "tray.full").tag(LibrarySection.documents)
                Label("Favorites", systemImage: "star").tag(LibrarySection.favorites)
                Label("Recents", systemImage: "clock").tag(LibrarySection.recents)
            }
            Section {
                Label("Trash", systemImage: "trash").tag(LibrarySection.trash)
                    .listRowBackground(isTrashDropTargeted ? Color.accentColor.opacity(0.25) : nil)
                    // Dropping a notebook or folder here moves it to the trash (recoverable).
                    .dropDestination(for: String.self) { payloads, _ in
                        let items = payloads.compactMap(model.dragged)
                        guard !items.isEmpty else { return false }
                        Task { for item in items { await model.trash(item) } }
                        return true
                    } isTargeted: { isTrashDropTargeted = $0 }
            }
        }
        .navigationTitle("BetterNotes")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.section == .trash {
            TrashView(model: model)
        } else {
            VStack(spacing: 0) {
                if model.section == .documents && !model.isSearching && !model.isAtRoot { breadcrumbBar }
                grid
            }
            .background(Color(.systemGroupedBackground))
            .searchable(text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
                        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search notebooks and folders")
            .onChange(of: model.searchText) { Task { await model.reload() } }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { position, url in
                    if position > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    let isLast = position == model.breadcrumbs.count - 1
                    Button(position == 0 ? "Documents" : url.lastPathComponent) {
                        Task { await model.show(folder: url) }
                    }
                    .font(isLast ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(isLast ? Color.primary : Color.accentColor)
                    .disabled(isLast)
                    // Dropping on a breadcrumb moves the dragged item up to that folder.
                    .dropDestination(for: String.self) { payloads, _ in
                        drop(payloads, onto: url)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private var grid: some View {
        let folders = model.shownFolders, notebooks = model.shownNotebooks
        // A ScrollView of tiles instead of a List: a List is a UIKit collection view that
        // handles drags itself and did not pass PDF drops on.
        return ScrollView {
            if folders.isEmpty && notebooks.isEmpty && model.hasLoaded {
                emptyState.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: libraryTileWidth + 16), spacing: 24, alignment: .top)],
                          alignment: .center, spacing: 28) {
                    ForEach(folders) { folder in
                        Button {
                            Task { await model.show(folder: folder.url); await model.select(.documents) }
                        } label: {
                            FolderTile(folder: folder, isDropTargeted: dropTargetFolder == folder.url)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { folderMenu(folder) }
                        .draggable(model.dragPayload(for: folder.url))
                        .dropDestination(for: String.self) { payloads, _ in
                            drop(payloads, onto: folder.url)
                        } isTargeted: { targeted in
                            if targeted { dropTargetFolder = folder.url } else if dropTargetFolder == folder.url { dropTargetFolder = nil }
                        }
                    }
                    ForEach(notebooks) { notebook in
                        Button { open(notebook) } label: {
                            NotebookTile(notebook: notebook, isFavorite: model.isFavorite(notebook))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { notebookMenu(notebook) }
                        .draggable(model.dragPayload(for: notebook.url))
                    }
                }
                .padding(24)
            }
        }
        .pdfDropTarget(isTargeted: $isDropTargeted, perform: handleDrop)
    }

    @ViewBuilder private var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch model.section {
            case .favorites:
                ContentUnavailableView("No favorites", systemImage: "star",
                                       description: Text("Touch and hold a notebook, then choose Add to Favorites."))
            case .recents:
                ContentUnavailableView("Nothing opened yet", systemImage: "clock",
                                       description: Text("Notebooks you open appear here."))
            default:
                ContentUnavailableView {
                    Label(model.isAtRoot ? "No notebooks yet" : "This folder is empty", systemImage: "books.vertical")
                } description: {
                    Text("Create a notebook or import a PDF. You can also drop a PDF here.")
                } actions: {
                    Button("New Notebook") { isCreatingNotebook = true }.buttonStyle(.borderedProminent)
                    Button("Import PDF", systemImage: "square.and.arrow.down") { isPickingPDF = true }
                }
            }
        }
    }

    // MARK: Menus

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.section == .trash {
                Button("Empty Trash", role: .destructive) { isConfirmingEmptyTrash = true }
                    .disabled(model.trashed.isEmpty)
            } else {
                Menu {
                    Picker("Sort by", selection: Binding(get: { model.index.sortKey }, set: {
                        model.setSort($0, ascending: model.index.sortAscending)
                    })) {
                        Text("Name").tag(LibrarySortKey.name)
                        Text("Date Modified").tag(LibrarySortKey.modified)
                        Text("Date Created").tag(LibrarySortKey.created)
                    }
                    Divider()
                    Picker("Order", selection: Binding(get: { model.index.sortAscending }, set: {
                        model.setSort(model.index.sortKey, ascending: $0)
                    })) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                Menu {
                    Button("New Notebook", systemImage: "square.and.pencil") { isCreatingNotebook = true }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        promptText = ""
                        prompt = .newFolder
                    }
                    Button("Import PDF", systemImage: "square.and.arrow.down") { isPickingPDF = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder private func notebookMenu(_ notebook: NotebookSummary) -> some View {
        Button("Open", systemImage: "book") { open(notebook) }
        Button(model.isFavorite(notebook) ? "Remove from Favorites" : "Add to Favorites",
               systemImage: model.isFavorite(notebook) ? "star.slash" : "star") {
            Task { await model.toggleFavorite(notebook) }
        }
        Button("Rename", systemImage: "pencil") {
            promptText = notebook.title
            prompt = .rename(notebook.url, notebook.title)
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(notebook.url) } }
        Button("Move to…", systemImage: "folder") { itemToMove = notebook.url }
        Menu("Cover Color", systemImage: "paintpalette") {
            ForEach(LibraryModel.coverColors, id: \.self) { hex in
                Button { Task { await model.setCoverColor(hex, for: notebook.url) } } label: {
                    Label(hex == notebook.coverColor ? "Current" : "Use", systemImage: hex == notebook.coverColor ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(Color(hex: hex))
            }
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            itemToTrash = (notebook.url, notebook.title)
        }
    }

    @ViewBuilder private func folderMenu(_ folder: FolderSummary) -> some View {
        Button("Rename", systemImage: "pencil") {
            promptText = folder.name
            prompt = .rename(folder.url, folder.name)
        }
        Button("Move to…", systemImage: "folder") { itemToMove = folder.url }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            itemToTrash = (folder.url, folder.name)
        }
    }

    // MARK: Prompt

    private var promptTitle: String {
        switch prompt {
        case .newFolder: "New Folder"
        case .rename: "Rename"
        case nil: ""
        }
    }

    private var promptButton: String {
        if case .newFolder = prompt { return "Create" }
        return "Rename"
    }

    private func commitPrompt() {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let prompt else { return }
        switch prompt {
        case .newFolder: Task { await model.createFolder(named: name) }
        case .rename(let url, _): Task { await model.rename(url, to: name) }
        }
    }

    // MARK: Actions

    private func drop(_ payloads: [String], onto destination: URL) -> Bool {
        let items = payloads.compactMap(model.dragged)
        guard !items.isEmpty else { return false }
        Task {
            for item in items { await model.move(item, into: destination) }
        }
        return true
    }

    private func open(_ notebook: NotebookSummary) {
        if let problem = notebook.problem {
            model.errorMessage = "\"\(notebook.title)\" cannot be opened: \(problem)"
            return
        }
        do {
            try session.open(NotebookPackage(url: notebook.url))
            model.recordOpened(notebook)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// A dragged file arrives as an `NSItemProvider`, a promise of data that the other app
    /// fulfils on request. `loadFileRepresentation` gives a temporary copy that the system
    /// deletes as soon as the callback returns, so the copy must be moved somewhere of ours
    /// right there, before the (slower) import starts.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        guard !pdfProviders.isEmpty else { return false }
        for provider in pdfProviders {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                guard let url else {
                    let message = error?.localizedDescription ?? "The dropped file could not be read."
                    Task { @MainActor in model.errorMessage = message }
                    return
                }
                // Own folder per drop, so the file keeps its name (it becomes the title).
                let folder = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                // The provider's temporary file may have no ".pdf" ending; the type already
                // told us it is a PDF, so make sure the name says so too.
                var name = url.lastPathComponent
                if !PDFImporter.isPDF(url) { name += ".pdf" }
                let copy = folder.appending(path: name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                } catch {
                    let message = error.localizedDescription
                    Task { @MainActor in model.errorMessage = message }
                    return
                }
                Task { @MainActor in
                    await session.importPDFs([copy])
                    await model.reload()
                    try? FileManager.default.removeItem(at: folder)  // our own temporary copy
                }
            }
        }
        return true
    }
}

#Preview {
    LibraryView().environment(WindowSession())
}

private extension View {
    /// Accepts a PDF dragged in from another app.
    func pdfDropTarget(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        onDrop(of: [.pdf], isTargeted: isTargeted, perform: perform)
    }
}
