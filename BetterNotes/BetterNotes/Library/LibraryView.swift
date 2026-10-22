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
                } else {
                    List(notebooks, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { open(url) }
                    }
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
            // Drag and drop from another app in Split View.
            .dropDestination(for: URL.self) { urls, _ in
                let pdfs = urls.filter(PDFImporter.isPDF)
                guard !pdfs.isEmpty else { return false }
                Task { await session.importPDFs(pdfs) }
                return true
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { reload() }
        }
    }

    private func reload() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: LibraryLocation.documents.root, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles)
        notebooks = (contents ?? [])
            .filter { $0.pathExtension == NotebookPackage.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
