import SwiftUI

/// Placeholder library screen. Milestone 5 replaces the empty state with the
/// real folder and notebook grid.
struct LibraryView: View {
    // @State is like React's useState: SwiftUI owns the value and re-runs
    // `body` whenever it changes. Unlike React there is no setter function;
    // you assign to the variable directly.
    @State private var showsComingSoon = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No notebooks yet", systemImage: "books.vertical")
            } description: {
                Text("Notebooks and imported PDFs will appear here.")
            } actions: {
                Button("New Notebook") { showsComingSoon = true }
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Library")
            .toolbar {
                // TEMPORARY: remove together with the Spike folder.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Spike") { StrokeCancelSpikeView() }
                }
            }
            .alert("Coming soon", isPresented: $showsComingSoon) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Creating notebooks arrives in milestone 2.")
            }
        }
    }
}

#Preview {
    LibraryView()
}
