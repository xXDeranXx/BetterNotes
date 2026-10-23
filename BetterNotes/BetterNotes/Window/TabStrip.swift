import SwiftUI
import UniformTypeIdentifiers

/// The row of open notebooks above the library and the editor, laid out like Goodnotes: the
/// house (library) on the left, then the tabs sharing the width. The active tab has the color
/// of the editor's top bar, so tab and bar look like one piece. Tap a tab to show it, × to
/// close it, hold for Close Other Tabs, and drag to reorder.
///
/// A horizontal `ScrollView` + `HStack`, not a `List` (see "Rules learned": lists swallow drops).
struct TabStrip: View {
    /// The editor's top bar and the active tab.
    static let barColor = Color(.systemBackground)
    /// The strip behind the other tabs.
    static let stripColor = Color(.systemGray5)
    /// Below this width the tabs stop shrinking and the strip scrolls instead.
    static let minimumTabWidth: CGFloat = 150

    @Environment(WindowSession.self) private var session
    /// The tab being dragged, so drops from anywhere else (text, PDFs) are ignored.
    @State private var draggedTab: UUID?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            homeButton
            GeometryReader { geometry in
                let count = CGFloat(max(session.tabs.count, 1))
                let width = max(Self.minimumTabWidth, geometry.size.width / count)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                                chip(for: tab, at: index).frame(width: width)
                            }
                        }
                    }
                    .scrollDisabled(width * count <= geometry.size.width + 0.5)
                    .onChange(of: session.activeTabID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id) } }
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(height: 44)
        .background(Self.stripColor.ignoresSafeArea(edges: .top))  // also behind the status bar
        .alert("Could not close the tab", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Home: the library, with all tabs kept (typing is finished by the editor's
    /// `beforeLeavingTab`). Filled while the library is on screen.
    private var homeButton: some View {
        let isActive = session.activeTabID == nil
        return Button("Library", systemImage: isActive ? "house.fill" : "house") {
            guard !isActive else { return }
            Task { await session.showLibraryAnimated() }
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .frame(width: 52, height: 40)
    }

    private func chip(for tab: NotebookTab, at index: Int) -> some View {
        let isActive = tab.id == session.activeTabID
        // A thin line between two inactive tabs, as in Goodnotes.
        let next = session.tabs.indices.contains(index + 1) ? session.tabs[index + 1].id : nil
        let showsSeparator = !isActive && next != nil && next != session.activeTabID
        return TabChip(tab: tab, isActive: isActive, showsSeparator: showsSeparator, select: { select(tab) }, close: { close(tab) })
            .id(tab.id)
            .contextMenu {
                Button("Close Other Tabs", systemImage: "xmark.square") { closeOthers(keeping: tab) }
                    .disabled(session.tabs.count < 2)
            }
            .onDrag {
                draggedTab = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, session: session, draggedTab: $draggedTab))
    }

    /// From the library a tab opens with the usual animation; between tabs it switches at once.
    private func select(_ tab: NotebookTab) {
        guard tab.id != session.activeTabID else { return }
        Task {
            do {
                if session.notebook == nil {
                    try await session.selectAnimated(tab.id)
                } else {
                    try session.select(tab.id)
                }
            } catch {
                errorMessage = "\"\(tab.title)\" could not be opened and was closed: \(error.localizedDescription)"
            }
        }
    }

    private func close(_ tab: NotebookTab) {
        Task {
            if await !session.closeTab(tab.id) {
                errorMessage = "\"\(tab.title)\" could not be saved, so it stays open. \(tab.notebook?.saveError ?? "")"
            }
        }
    }

    private func closeOthers(keeping tab: NotebookTab) {
        Task {
            await session.closeOtherTabs(keeping: tab.id)
            if session.tabs.count > 1 {
                errorMessage = "Some tabs could not be saved, so they stay open."
            }
        }
    }
}

private struct TabChip: View {
    let tab: NotebookTab
    let isActive: Bool
    let showsSeparator: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .padding(.leading, 14)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)
            .accessibilityLabel("Close \(tab.title)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? TabStrip.barColor : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
        .overlay(alignment: .trailing) {
            // A plain Divider would be horizontal here (it follows the stack around it).
            if showsSeparator { Rectangle().fill(Color(.separator)).frame(width: 1, height: 18) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tab:\(tab.title)")
    }
}

/// Moves the dragged tab to where the finger is while dragging (like reordering home screen
/// icons), so the drop itself has nothing left to do.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let session: WindowSession
    @Binding var draggedTab: UUID?

    func validateDrop(info: DropInfo) -> Bool { draggedTab != nil }

    func dropEntered(info: DropInfo) {
        guard let draggedTab, draggedTab != target, let index = session.tabs.firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.easeInOut(duration: 0.2)) { session.moveTab(draggedTab, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggedTab = nil
        return true
    }
}
