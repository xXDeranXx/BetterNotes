import SwiftUI

/// The root of every window. `WindowGroup` builds a fresh copy of this view for each window
/// (scene), and `@State` keeps one `WindowSession` alive for as long as that window exists.
/// A plain `let` would create a new session each time SwiftUI rebuilds the view.
struct RootView: View {
    @State private var session = WindowSession()

    var body: some View {
        // While a notebook zooms open, the library stays underneath and the editor fades in
        // on top of it (see `WindowSession.openZooming`); otherwise it is one or the other.
        ZStack {
            if session.notebook == nil || session.coverTransition != nil || session.isClosing {
                LibraryView()
            }
            if let notebook = session.notebook {
                let zoom = session.coverTransition
                EditorView(notebook: notebook)
                    .opacity(zoom.map { $0.expanded ? 1 : 0 } ?? (session.closeFaded ? 0 : 1))
                    .scaleEffect(session.closeFaded ? 0.94 : 1)
                    .allowsHitTesting(!session.isZooming && !session.isClosing)
            }
        }
        .overlay { CoverZoomView(session: session) }
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

/// The page-colored cover that zooms from a notebook's tile to the whole window.
private struct CoverZoomView: View {
    let session: WindowSession

    var body: some View {
        if let transition = session.coverTransition {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let full = CGRect(origin: .zero, size: proxy.size)
                let rect = transition.expanded ? full : transition.from.offsetBy(dx: -origin.x, dy: -origin.y)
                ZStack {
                    Color.white
                    if let image = transition.image {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .opacity(transition.expanded ? 0 : 1)
                .clipShape(RoundedRectangle(cornerRadius: transition.expanded ? 0 : 10))
                .shadow(color: .black.opacity(transition.expanded ? 0 : 0.25), radius: 8, y: 4)
                .position(x: rect.midX, y: rect.midY)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
