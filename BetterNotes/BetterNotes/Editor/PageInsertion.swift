import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the user wants to insert as new pages.
enum InsertKind {
    case pdf, photo, image
}

extension PageActions {
    /// Files outside the app are only readable after asking for temporary access; the file is
    /// read into memory completely, so the pages do not depend on it afterwards.
    private func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Inserts all pages of each PDF at `index`, one undo step per PDF.
    func insertPDFs(_ urls: [URL], at index: Int, reveal: Bool) {
        attempt {
            var position = index
            var firstNew: UUID?
            for url in urls {
                guard let document = PDFDocument(data: try readFile(url)) else { throw NotebookError.pdfUnreadable }
                let ids = try notebook.insertPages(
                    try Notebook.makeEntries(from: document), at: position, actionName: "Insert PDF Pages")
                position += ids.count
                firstNew = firstNew ?? ids.first
            }
            if reveal, let firstNew { navigator.goTo(firstNew) }
        }
    }

    /// Each image becomes a page of its own (see `Notebook.makeImagePage`).
    func insertImages(_ images: [Data], at index: Int, reveal: Bool) {
        attempt {
            var position = index
            var firstNew: UUID?
            for data in images {
                let ids = try notebook.insertPages(
                    [try Notebook.makeImagePage(from: data)], at: position, actionName: "Insert Image Page")
                position += ids.count
                firstNew = firstNew ?? ids.first
            }
            if reveal, let firstNew { navigator.goTo(firstNew) }
        }
    }

    func insertImageFiles(_ urls: [URL], at index: Int, reveal: Bool) {
        attempt { insertImages(try urls.map(readFile), at: index, reveal: reveal) }
    }
}

/// The menu entries that start an insertion; the pickers themselves are in `pageInsertion`.
struct InsertMenuItems: View {
    @Binding var kind: InsertKind?

    var body: some View {
        Button("PDF from Files…", systemImage: "doc.badge.plus") { kind = .pdf }
        Button("Photo…", systemImage: "photo") { kind = .photo }
        Button("Image from Files…", systemImage: "folder") { kind = .image }
    }
}

extension View {
    /// Adds the Files and Photos pickers for `kind` to this view. When the user has chosen,
    /// the pages are inserted at `insertionIndex()` (asked at that moment, not when the
    /// picker opened) and `kind` is reset. `reveal` scrolls the editor to the new pages.
    func pageInsertion(
        kind: Binding<InsertKind?>, actions: PageActions, reveal: Bool, insertionIndex: @escaping () -> Int
    ) -> some View {
        modifier(PageInsertionModifier(kind: kind, actions: actions, reveal: reveal, insertionIndex: insertionIndex))
    }
}

private struct PageInsertionModifier: ViewModifier {
    @Binding var kind: InsertKind?
    let actions: PageActions
    let reveal: Bool
    let insertionIndex: () -> Int

    /// `kind` is already `nil` again when the picker reports back, so the choice is kept here.
    @State private var activeKind: InsertKind = .pdf
    @State private var photoSelection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .onChange(of: kind) { _, new in if let new { activeKind = new } }
            // One file importer for both PDFs and images: two on the same view fight
            // over which one is shown.
            .fileImporter(
                isPresented: Binding(
                    get: { kind == .pdf || kind == .image }, set: { if !$0 { kind = nil } }),
                allowedContentTypes: activeKind == .image || kind == .image ? [.image] : [.pdf],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    if activeKind == .image {
                        actions.insertImageFiles(urls, at: insertionIndex(), reveal: reveal)
                    } else {
                        actions.insertPDFs(urls, at: insertionIndex(), reveal: reveal)
                    }
                case .failure(let error):
                    actions.report(error.localizedDescription)
                }
            }
            .photosPicker(
                isPresented: Binding(get: { kind == .photo }, set: { if !$0 { kind = nil } }),
                selection: $photoSelection, matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task {
                    // The picker hands over promises; the image data is loaded now.
                    var images: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { images.append(data) }
                    }
                    if images.isEmpty {
                        actions.report("The photo could not be loaded.")
                    } else {
                        actions.insertImages(images, at: insertionIndex(), reveal: reveal)
                    }
                }
            }
    }
}
