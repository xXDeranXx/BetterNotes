import SwiftUI

/// Lists the other notebooks of the library; choosing one asks whether to copy or move the
/// selected pages there. Milestone 5 turns the library into folders; this list then follows.
struct TransferSheet: View {
    let sourceURL: URL
    let pageCount: Int
    let choose: (_ target: URL, _ move: Bool) -> Void
    let cancel: () -> Void

    @State private var chosen: URL?
    private let notebooks: [URL]

    init(sourceURL: URL, pageCount: Int, choose: @escaping (URL, Bool) -> Void, cancel: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.pageCount = pageCount
        self.choose = choose
        self.cancel = cancel
        notebooks = LibraryScanner.allNotebooks(under: LibraryLocation.documents.root).filter { $0.problem == nil }.map(\.url).filter {
            $0.standardizedFileURL.resolvingSymlinksInPath() != sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    private func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    var body: some View {
        NavigationStack {
            Group {
                if notebooks.isEmpty {
                    ContentUnavailableView(
                        "No other notebooks", systemImage: "books.vertical",
                        description: Text("Create or import another notebook first."))
                } else {
                    List(notebooks, id: \.self) { url in
                        Button(name(url)) { chosen = url }
                    }
                }
            }
            .navigationTitle("Move or Copy \(pageCount) \(pageCount == 1 ? "Page" : "Pages") To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
            .confirmationDialog(
                chosen.map { "To \"\(name($0))\"" } ?? "", isPresented: Binding(
                    get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                titleVisibility: .visible
            ) {
                Button("Copy") { if let chosen { choose(chosen, false) } }
                Button("Move") { if let chosen { choose(chosen, true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The pages are added at the end, with their ink. Copy keeps them here; Move removes them here.")
            }
        }
    }
}
