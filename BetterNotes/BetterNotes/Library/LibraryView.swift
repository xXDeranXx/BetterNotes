import SwiftUI
import UniformTypeIdentifiers

/// TEMPORARY library screen (milestone 2): a flat list of the notebooks in Documents and a
/// button that creates an "Untitled" one. Milestone 5 replaces it with folders, covers,
/// sorting and search.
struct LibraryView: View {
    @Environment(WindowSession.self) private var session
    // @State is like React's useState: SwiftUI owns the value and re-runs `body` whenever
    // it changes. Unlike React there is no setter function; you assign to the variable.
    @State private var notebooks: [URL] = []
    @State private var errorMessage: String?
    @State private var isPickingPDF = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationStack {
            Group {
                if notebooks.isEmpty {
                    ContentUnavailableView {
                        Label("No notebooks yet", systemImage: "books.vertical")
                    } description: {
                        Text("Notebooks and imported PDFs will appear here.")
                    } actions: {
                        Button("New Notebook", action: createNotebook)
                            .buttonStyle(.borderedProminent)
                        Button("Import PDF", systemImage: "square.and.arrow.down") { isPickingPDF = true }
                    }
                    .pdfDropTarget(isTargeted: $isDropTargeted, perform: handleDrop)
                } else {
                    // A ScrollView of buttons instead of a List: a List is a UIKit collection
                    // view that handles drags itself and did not pass PDF drops on. The
                    // milestone 5 grid will be built the same way.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(notebooks, id: \.self) { url in
                                Button { open(url) } label: {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading)
                            }
                        }
                    }
                    .pdfDropTarget(isTargeted: $isDropTargeted, perform: handleDrop)
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import PDF", systemImage: "square.and.arrow.down") { isPickingPDF = true }
                    Button("New Notebook", systemImage: "plus", action: createNotebook)
                }
            }
            // The system's Files picker. It hands back URLs we may read for a short while.
            .fileImporter(
                isPresented: $isPickingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): Task { await session.importPDFs(urls) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { reload() }
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
                    Task { @MainActor in errorMessage = message }
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
                    Task { @MainActor in errorMessage = message }
                    return
                }
                Task { @MainActor in
                    await session.importPDFs([copy])
                    try? FileManager.default.removeItem(at: folder)  // our own temporary copy
                }
            }
        }
        return true
    }

    private func reload() {
        notebooks = LibraryLocation.documents.notebookURLs()
    }

    private func createNotebook() {
        do {
            let package = try NotebookPackage.create(
                in: LibraryLocation.documents.root, title: "Untitled", template: .lined,
                size: .a4Portrait, coverColor: "#4F6BED")
            reload()
            try session.open(package)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        do {
            try session.open(NotebookPackage(url: url))
        } catch {
            errorMessage = error.localizedDescription
        }
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
