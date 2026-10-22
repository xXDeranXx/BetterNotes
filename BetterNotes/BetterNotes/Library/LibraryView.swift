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
    @State private var moveRequest: MoveRequest?
    @State private var styleRequest: FolderSummary?
    @State private var isConfirmingDeleteSelection = false
    @State private var itemToTrash: (url: URL, name: String)?
    @State private var dropTargetFolder: URL?
    @State private var isConfirmingEmptyTrash = false
    @State private var isTrashDropTargeted = false
    @State private var exportNotebook: Notebook?
    @State private var backupRequest: BackupRequest?
    @State private var isPickingImportFolder = false
    @State private var infoMessage: String?
    @State private var isReminderDismissed = false

    private struct BackupRequest: Identifiable {
        let id = UUID()
        let source: URL
        let title: String
        let isWholeLibrary: Bool
    }

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
                    .navigationTitle(model.isSelecting ? (model.selection.isEmpty ? "Select Items" : "\(model.selection.count) Selected") : model.title)
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
        .sheet(item: Binding(get: { exportNotebook.map(ExportItem.init) }, set: { if $0 == nil { exportNotebook = nil } })) { item in
            ExportSheet(notebook: item.notebook) { exportNotebook = nil }
        }
        .sheet(item: $backupRequest) { request in
            BackupSheet(
                source: request.source, title: request.title, isWholeLibrary: request.isWholeLibrary,
                lastBackup: model.index.lastBackup,
                didBackUp: { if request.isWholeLibrary { model.recordBackup() } },
                close: { backupRequest = nil })
        }
        .fileImporter(isPresented: $isPickingImportFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { infoMessage = await model.importFolder(from: url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Done", isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
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
        .sheet(item: $styleRequest) { folder in
            FolderStyleSheet(
                name: folder.name, style: folder.style,
                save: { style in
                    styleRequest = nil
                    Task { await model.setFolderStyle(style, for: folder.url) }
                },
                cancel: { styleRequest = nil })
        }
        .sheet(item: $moveRequest) { request in
            FolderPickerSheet(
                items: request.urls, root: model.location.root, folders: model.allFolders,
                choose: { destination in
                    moveRequest = nil
                    Task {
                        if request.isSelection {
                            await model.moveSelection(into: destination)
                        } else if let url = request.urls.first {
                            await model.move(url, into: destination)
                        }
                    }
                },
                cancel: { moveRequest = nil })
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(promptButton) { commitPrompt() }
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

    /// Confirmation for moving one tile to the trash, attached to that tile so the popover
    /// points at it.
    private func trashDialog(for url: URL, name: String) -> Binding<Bool> {
        Binding(get: { itemToTrash?.url == url }, set: { if !$0 && itemToTrash?.url == url { itemToTrash = nil } })
    }

    private struct MoveRequest: Identifiable {
        let id = UUID()
        let urls: [URL]
        var isSelection = false
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
                if showsBackupReminder { backupReminder }
                grid
            }
            .background(Color(.systemGroupedBackground))
            .searchable(text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
                        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search notebooks and folders")
            .onChange(of: model.searchText) { Task { await model.reload() } }
        }
    }

    private var showsBackupReminder: Bool {
        model.section == .documents && model.isAtRoot && !model.isSearching && !model.isSelecting
            && !isReminderDismissed && model.hasLoaded
            && !(model.contents.notebooks.isEmpty && model.contents.folders.isEmpty)
            && model.index.isBackupDue()
    }

    private var backupReminder: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.index.lastBackup == nil ? "No backup yet" : "Your last backup is older than \(LibraryIndex.backupReminderDays) days")
                    .font(.subheadline.weight(.semibold))
                Text("Deleting the app deletes all notebooks. See how big a backup is before you decide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back Up…") { backupRequest = BackupRequest(source: model.location.root, title: "Back Up Library", isWholeLibrary: true) }
                .buttonStyle(.bordered)
            Button("Not Now", systemImage: "xmark") { isReminderDismissed = true }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.regularMaterial)
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
        // handles drags itself and did not pass PDF drops on. The list layout is a
        // LazyVStack for the same reason.
        return ScrollView {
            if folders.isEmpty && notebooks.isEmpty && model.hasLoaded {
                emptyState.frame(maxWidth: .infinity).padding(.top, 80)
            } else if model.index.layout == .list {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        folderButton(folder) {
                            FolderRow(folder: folder, isDropTargeted: dropTargetFolder == folder.url, isSelected: selectionState(folder.url))
                        }
                        Divider().padding(.leading, 20)
                    }
                    ForEach(notebooks) { notebook in
                        notebookButton(notebook) {
                            NotebookRow(notebook: notebook, isFavorite: model.isFavorite(notebook), isSelected: selectionState(notebook.url))
                        }
                        Divider().padding(.leading, 20)
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: libraryTileWidth + 16), spacing: 24, alignment: .top)],
                          alignment: .center, spacing: 28) {
                    ForEach(folders) { folder in
                        folderButton(folder) {
                            FolderTile(folder: folder, isDropTargeted: dropTargetFolder == folder.url, isSelected: selectionState(folder.url))
                        }
                    }
                    ForEach(notebooks) { notebook in
                        notebookButton(notebook) {
                            NotebookTile(notebook: notebook, isFavorite: model.isFavorite(notebook), isSelected: selectionState(notebook.url))
                        }
                    }
                }
                .padding(24)
            }
        }
        .pdfDropTarget(isTargeted: $isDropTargeted, perform: handleDrop)
    }

    /// `nil` outside selection mode, otherwise whether the item is ticked.
    private func selectionState(_ url: URL) -> Bool? {
        model.isSelecting ? model.selection.contains(url) : nil
    }

    /// A folder as a button: opens it (or ticks it while selecting), with its menu, trash
    /// confirmation, drag source and drop target. The same for tile and row layouts.
    private func folderButton<Label: View>(_ folder: FolderSummary, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if model.isSelecting {
                model.toggleSelection(folder.url)
            } else {
                Task { await model.show(folder: folder.url); await model.select(.documents) }
            }
        } label: { label() }
        .buttonStyle(.plain)
        .confirmationDialog("Move \"\(folder.name)\" to the trash?", isPresented: trashDialog(for: folder.url, name: folder.name), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await model.trash(folder.url) } }
        } message: { Text("You can put it back from the Trash for 30 days.") }
        .contextMenu { folderMenu(folder) }
        .draggable(model.dragPayload(for: folder.url))
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, onto: folder.url)
        } isTargeted: { targeted in
            if targeted { dropTargetFolder = folder.url } else if dropTargetFolder == folder.url { dropTargetFolder = nil }
        }
    }

    private func notebookButton<Label: View>(_ notebook: NotebookSummary, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if model.isSelecting { model.toggleSelection(notebook.url) } else { open(notebook) }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .confirmationDialog("Move \"\(notebook.title)\" to the trash?", isPresented: trashDialog(for: notebook.url, name: notebook.title), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await model.trash(notebook.url) } }
        } message: { Text("You can put it back from the Trash for 30 days.") }
        .contextMenu { notebookMenu(notebook) }
        .draggable(model.dragPayload(for: notebook.url))
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
                    .confirmationDialog("Delete everything in the trash permanently?", isPresented: $isConfirmingEmptyTrash, titleVisibility: .visible) {
                        Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
                    } message: {
                        Text("This cannot be undone.")
                    }
            } else if model.isSelecting {
                Button(model.allSelected ? "Select None" : "Select All") {
                    if model.allSelected { model.endSelecting(); model.startSelecting() } else { model.selectAll() }
                }
                Button("Done") { model.endSelecting() }.fontWeight(.semibold)
            } else {
                Button("Select") { model.startSelecting() }
                Button {
                    model.setLayout(model.index.layout == .grid ? .list : .grid)
                } label: {
                    Label(model.index.layout == .grid ? "Show as List" : "Show as Grid",
                          systemImage: model.index.layout == .grid ? "list.bullet" : "square.grid.2x2")
                }
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
                    Button("Import Folder…", systemImage: "folder.badge.gearshape") { isPickingImportFolder = true }
                    Divider()
                    Button("Back Up Library…", systemImage: "externaldrive") {
                        backupRequest = BackupRequest(source: model.location.root, title: "Back Up Library", isWholeLibrary: true)
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        // Bulk actions while selecting. The confirmation is attached to the Delete button, so
        // its popover points at it.
        ToolbarItemGroup(placement: .bottomBar) {
            if model.isSelecting {
                Button("Move to…", systemImage: "folder") {
                    moveRequest = MoveRequest(urls: Array(model.selection), isSelection: true)
                }
                .disabled(model.selection.isEmpty)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { isConfirmingDeleteSelection = true }
                    .disabled(model.selection.isEmpty)
                    .confirmationDialog(
                        "Move \(model.selection.count) \(model.selection.count == 1 ? "item" : "items") to the trash?",
                        isPresented: $isConfirmingDeleteSelection, titleVisibility: .visible
                    ) {
                        Button("Move to Trash", role: .destructive) { Task { await model.trashSelection() } }
                    } message: { Text("You can put them back from the Trash for 30 days.") }
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
        Button("Move to…", systemImage: "folder") { moveRequest = MoveRequest(urls: [notebook.url]) }
        Button("Export PDF…", systemImage: "square.and.arrow.up") { export(notebook) }
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
        Button("Change Icon…", systemImage: "face.smiling") { styleRequest = folder }
        Button("Move to…", systemImage: "folder") { moveRequest = MoveRequest(urls: [folder.url]) }
        Button("Back Up…", systemImage: "externaldrive") {
            backupRequest = BackupRequest(source: folder.url, title: folder.name, isWholeLibrary: false)
        }
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

    /// Opens the notebook just to read it for the export sheet. Not in a window, so it is not
    /// claimed in the registry; a notebook that a window has open is refused, because that
    /// window may hold ink that is not on disk yet.
    private func export(_ notebook: NotebookSummary) {
        if let problem = notebook.problem {
            model.errorMessage = "\"\(notebook.title)\" cannot be exported: \(problem)"
            return
        }
        guard !OpenNotebookRegistry.shared.isOpen(at: notebook.url) else {
            model.errorMessage = "\"\(notebook.title)\" is open in a window. Export it from there, or close it first."
            return
        }
        do {
            exportNotebook = try Notebook.open(NotebookPackage(url: notebook.url))
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func open(_ notebook: NotebookSummary) {
        if let problem = notebook.problem {
            model.errorMessage = "\"\(notebook.title)\" cannot be opened: \(problem)"
            return
        }
        let package = NotebookPackage(url: notebook.url)
        Task {
            do {
                try await session.openAnimated(package)
                model.recordOpened(notebook)
            } catch {
                model.errorMessage = error.localizedDescription
            }
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

/// Gives a `Notebook` an identity for `.sheet(item:)`.
private struct ExportItem: Identifiable {
    let notebook: Notebook
    var id: ObjectIdentifier { ObjectIdentifier(notebook) }
}
