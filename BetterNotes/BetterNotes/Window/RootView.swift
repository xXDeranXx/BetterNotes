import SwiftUI

/// The root of every window. `WindowGroup` builds a fresh copy of this view for each window
/// (scene), and `@State` keeps one `WindowSession` alive for as long as that window exists.
/// A plain `let` would create a new session each time SwiftUI rebuilds the view.
struct RootView: View {
    @State private var session = WindowSession()
    @Environment(\.scenePhase) private var scenePhase
    /// This window's key in `TabStore` (tabs step 5). `@SceneStorage` is storage that belongs
    /// to this one window: iPadOS keeps it while the window exists and hands it back when it
    /// restores the window, like `sessionStorage` per browser tab. The tabs themselves are in
    /// `TabStore` (see there why).
    @SceneStorage("windowKey") private var windowKey: String?
    @State private var didRestore = false
    @State private var restoreNote: String?
    /// The restored tab that was shown, waiting for the window to become active.
    @State private var tabToShow: UUID?

    var body: some View {
        // The tab strip sits on top while any notebook is open; below it the library or the editor.
        VStack(spacing: 0) {
            if !session.tabs.isEmpty {
                TabStrip()
            }
            content
        }
        .debugOverlay()  // temporary, see Debug/
        .environment(session)
        // Lets other windows bring this one forward (see `WindowDirectory`).
        .background(SceneReader { session.scene = $0 })
        .task {
            guard !didRestore else { return }
            didRestore = true
            let (key, stored) = TabStore.load(windowKey: windowKey)
            windowKey = key  // also when skipping, so this launch's tabs are kept
            // UI tests start in the library (launch argument `-skipTabRestore YES`).
            guard !UserDefaults.standard.bool(forKey: "skipTabRestore"), let saved = stored else { return }
            let (skipped, shown) = session.restoreTabs(saved, root: LibraryLocation.documents.root)
            if skipped > 0 {
                restoreNote = skipped == 1
                    ? "One tab could not be opened again: its notebook was deleted or is open in another window."
                    : "\(skipped) tabs could not be opened again: their notebooks were deleted or are open in another window."
            }
            tabToShow = shown
            // The view's scenePhase can be stale here, so ask the app itself; wait at most 5 s.
            for _ in 0..<50 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(100))
            }
            showRestoredTab()
        }
        // Every change of the tabs (open, close, reorder, rename, the remembered position) is
        // kept at once, so a quit at any moment restores what was there.
        .onChange(of: session.savedTabs(root: LibraryLocation.documents.root)) { _, tabs in
            // Not before they were restored, so they are not overwritten with nothing.
            guard didRestore, let windowKey else { return }
            TabStore.save(tabs, windowKey: windowKey)
        }
        .alert(
            "Tabs not restored", isPresented: Binding(
                get: { restoreNote != nil }, set: { if !$0 { restoreNote = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreNote ?? "")
        }
        // The editor saves the shown notebook; background tabs that still hold a model are
        // saved here (a second save of the shown one finds nothing to do).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveAllInBackground() }
        }
        // "Open in BetterNotes" from the share sheet or the Files app arrives here as a URL.
        // Like a route change in a React app: the system hands the window a URL and the
        // window decides what to show.
        .onOpenURL { url in
            // A notebook of the library (for example tapped in the Files app) opens in a tab, or
            // brings forward the window that has it; anything else is imported as a PDF.
            if url.pathExtension == NotebookPackage.fileExtension,
                url.standardizedFileURL.path.hasPrefix(LibraryLocation.documents.root.standardizedFileURL.path + "/")
            {
                do { try session.open(NotebookPackage(url: url)) } catch NotebookError.openInOtherWindow {
                } catch { session.importError = error.localizedDescription }
            } else {
                Task { await session.importPDFs([url]) }
            }
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

    private func showRestoredTab() {
        guard let id = tabToShow else { return }
        tabToShow = nil
        do {
            try session.select(id)
        } catch {
            restoreNote = "A tab could not be opened again: \(error.localizedDescription)"
        }
    }

    /// While a notebook opens or goes home, the library stays underneath and the editor fades
    /// in or out on top of it (see `WindowSession.openAnimated`); otherwise it is one or the other.
    private var content: some View {
        ZStack {
            if session.notebook == nil || session.isOpening || session.isClosing {
                LibraryView()
            }
            if let notebook = session.notebook {
                // Opening fades the editor in and going home fades it out, both with a slight
                // grow or shrink; the library shows through in between.
                let shown = session.isOpening ? session.openRevealed : !session.closeFaded
                EditorView(notebook: notebook, tab: session.activeTab)
                    // A new editor (with fresh @State) for each tab; without the id SwiftUI
                    // would keep the old one and only hand it the other notebook.
                    .id(session.activeTabID)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.94)
                    .allowsHitTesting(!session.isOpening && !session.isClosing)
            }
        }
    }
}
