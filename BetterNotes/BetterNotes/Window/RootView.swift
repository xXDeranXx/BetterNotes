import SwiftUI

/// The root of every window. `WindowGroup` builds a fresh copy of this view for each window
/// (scene), and `@State` keeps one `WindowSession` alive for as long as that window exists.
/// A plain `let` would create a new session each time SwiftUI rebuilds the view.
struct RootView: View {
    @State private var session = WindowSession()

    var body: some View {
        Group {
            if let notebook = session.notebook {
                EditorView(notebook: notebook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                LibraryView()
                    .transition(.opacity)
            }
        }
        // Opening or closing a notebook fades and eases in instead of cutting. SwiftUI animates
        // the swap above whenever the value below changes (like a CSS transition in React).
        .animation(.smooth(duration: 0.35), value: session.notebook != nil)
        .environment(session)
        // "Open in BetterNotes" from the share sheet or the Files app arrives here as a URL.
        // Like a route change in a React app: the system hands the window a URL and the
        // window decides what to show.
        .onOpenURL { url in
            Task { await session.importPDFs([url]) }
        }
        .alert(
            "Could not import", isPresented: Binding(
                get: { session.importError != nil }, set: { if !$0 { session.importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.importError ?? "")
        }
    }
}
