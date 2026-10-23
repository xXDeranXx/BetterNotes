import SwiftUI
import UniformTypeIdentifiers

/// Does the work behind `ExportSheet`: runs the export, remembers progress, and keeps the
/// temporary file until it was shared or saved.
@Observable
final class ExportModel {
    enum Destination { case share, folder }

    let notebook: Notebook
    var isWorking = false
    var progress = 0.0
    var errorMessage: String?
    var savedMessage: String?
    var sharedFile: SharedFile?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(notebook: Notebook) { self.notebook = notebook }

    func start(pageIDs: Set<UUID>?, destination: Destination) {
        guard !isWorking else { return }
        isWorking = true
        progress = 0
        task = Task {
            defer { isWorking = false }
            do {
                let file = try await NotebookExporter.export(notebook, pageIDs: pageIDs) { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
                switch destination {
                case .share:
                    sharedFile = SharedFile(url: file)  // removed when the share sheet closes
                case .folder:
                    defer { NotebookExporter.discard(file) }
                    let saved = try ExportFolderStore.save(file)
                    savedMessage = "Saved \"\(saved.file)\" in \"\(saved.folder)\"."
                }
            } catch is CancellationError {
                // The user pressed Cancel: nothing to say.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func finishSharing() {
        if let file = sharedFile { NotebookExporter.discard(file.url) }
        sharedFile = nil
    }
}

/// "Export PDF": all pages or chosen pages, then share or save to the remembered folder.
struct ExportSheet: View {
    @State private var model: ExportModel
    @State private var thumbnails: ThumbnailStore
    @State private var scope = Scope.all
    @State private var selection: Set<UUID> = []
    @State private var isPickingFolder = false
    @State private var folderName = ExportFolderStore.folderName
    let close: () -> Void

    private enum Scope { case all, choose }

    init(notebook: Notebook, thumbnails: ThumbnailStore? = nil, close: @escaping () -> Void) {
        _model = State(initialValue: ExportModel(notebook: notebook))
        _thumbnails = State(initialValue: thumbnails ?? ThumbnailStore(notebook: notebook))
        self.close = close
    }

    private var notebook: Notebook { model.notebook }
    private var chosenIDs: Set<UUID> { selection.intersection(notebook.pages.map(\.id)) }
    private var pageIDs: Set<UUID>? { scope == .all ? nil : chosenIDs }
    private var canExport: Bool { !model.isWorking && (scope == .all || !chosenIDs.isEmpty) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if notebook.meta.isWhiteboard {
                    // One page around everything on the board; nothing to choose.
                    ContentUnavailableView(
                        "The whole whiteboard", systemImage: "scribble",
                        description: Text("One PDF page around everything you drew or placed, with the background. The whiteboard itself is not changed."))
                } else {
                Picker("Pages", selection: $scope) {
                    Text("All \(notebook.pages.count) Pages").tag(Scope.all)
                    Text("Choose Pages").tag(Scope.choose)
                }
                .pickerStyle(.segmented)
                .padding()

                if scope == .choose {
                    pageGrid
                } else {
                    ContentUnavailableView(
                        "The whole notebook", systemImage: "doc.richtext",
                        description: Text("Pages stay sharp, text stays selectable, and your ink is added on top. The notebook itself is not changed."))
                }
                }

                footer
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.isWorking ? "Cancel Export" : "Close") {
                        if model.isWorking { model.cancel() } else { close() }
                    }
                }
                if scope == .choose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(chosenIDs.count == notebook.pages.count ? "Select None" : "Select All") {
                            selection = chosenIDs.count == notebook.pages.count ? [] : Set(notebook.pages.map(\.id))
                        }
                    }
                }
            }
            .sheet(item: $model.sharedFile, onDismiss: { model.finishSharing() }) { file in
                ShareSheet(url: file.url) { _ in
                    model.finishSharing()
                }
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        try ExportFolderStore.remember(url)
                        folderName = ExportFolderStore.folderName
                        model.start(pageIDs: pageIDs, destination: .folder)
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .alert("Export failed", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Exported", isPresented: Binding(
                get: { model.savedMessage != nil }, set: { if !$0 { model.savedMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.savedMessage ?? "")
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 16)], spacing: 18) {
                ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                    let isSelected = selection.contains(page.id)
                    PageThumbnailView(page: page, number: index + 1, thumbnails: thumbnails, isHighlighted: isSelected)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .background(Circle().fill(.background).padding(2))
                                .padding(6)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelected { selection.remove(page.id) } else { selection.insert(page.id) }
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            if model.isWorking {
                ProgressView(value: model.progress) { Text("Making the PDF…").font(.callout) }
                    .padding(.horizontal)
            }
            HStack(spacing: 12) {
                Button {
                    model.start(pageIDs: pageIDs, destination: .share)
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)

                if let folderName {
                    Button {
                        model.start(pageIDs: pageIDs, destination: .folder)
                    } label: {
                        Label("Save to \"\(folderName)\"", systemImage: "folder").frame(maxWidth: .infinity).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canExport)
                    Button("Change Folder…", systemImage: "gearshape") { isPickingFolder = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking)
                } else {
                    Button {
                        isPickingFolder = true
                    } label: {
                        Label("Choose Export Folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canExport)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }
}
