import SwiftUI

/// The root of every window. `WindowGroup` builds a fresh copy of this view for each window
/// (scene), and `@State` keeps one `WindowSession` alive for as long as that window exists.
/// A plain `let` would create a new session each time SwiftUI rebuilds the view.
struct RootView: View {
    @State private var session = WindowSession()

    var body: some View {
        // While a notebook opens or closes, the library stays underneath and the editor fades
        // in or out on top of it (see `WindowSession.openAnimated`); otherwise it is one or the other.
        ZStack {
            if session.notebook == nil || session.isOpening || session.isClosing {
                LibraryView()
            }
            if let notebook = session.notebook {
                // Opening fades the editor in and closing fades it out, both with a slight
                // grow or shrink; the library shows through in between.
                let shown = session.isOpening ? session.openRevealed : !session.closeFaded
                EditorView(notebook: notebook)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.94)
                    .allowsHitTesting(!session.isOpening && !session.isClosing)
            }
        }
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
