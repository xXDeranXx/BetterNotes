import SwiftUI
import UIKit

/// The windows of the app that are alive right now, so one window can reach another (M9):
/// bring the window that has a notebook open to the front, or copy a page dragged over from
/// another window's notebook.
///
/// Only weak references: a window that goes away disappears from here on its own. The
/// windows' state itself stays in each `WindowSession` (SPEC, architecture decision 5); this
/// is only an address book.
@MainActor
enum WindowDirectory {
    private final class Entry {
        weak var session: WindowSession?
        init(_ session: WindowSession) { self.session = session }
    }

    private static var entries: [UUID: Entry] = [:]

    static func register(_ session: WindowSession) {
        entries = entries.filter { $0.value.session != nil }
        entries[session.windowID] = Entry(session)
    }

    static func session(for windowID: UUID) -> WindowSession? {
        entries[windowID]?.session
    }

    /// The loaded notebook (in any window, any tab) that has a page with this id.
    static func notebook(containingPage pageID: UUID) -> Notebook? {
        for entry in entries.values {
            for tab in entry.session?.tabs ?? [] {
                if let notebook = tab.notebook, notebook.pages.contains(where: { $0.id == pageID }) {
                    return notebook
                }
            }
        }
        return nil
    }

    /// Shows the tab that has the notebook at `url` in its window and brings that window to
    /// the front. `false` if no live window has it (then the caller says "already open").
    static func bringForward(_ url: URL, registry: OpenNotebookRegistry = .shared) -> Bool {
        guard let owner = registry.owner(of: url), let session = session(for: owner.window) else { return false }
        try? session.select(owner.tab)
        if let scene = session.scene {
            // Asks iPadOS to show that window (in front, or next to this one in Split View).
            UIApplication.shared.activateSceneSession(
                for: UISceneSessionActivationRequest(session: scene.session), errorHandler: nil)
        }
        return true
    }
}

/// Tells the session which `UIWindowScene` its window lives in (SwiftUI does not say), so
/// another window can bring it forward. An empty view that reports its window's scene.
struct SceneReader: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReportingView, context: Context) {}

    final class ReportingView: UIView {
        var found: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}
