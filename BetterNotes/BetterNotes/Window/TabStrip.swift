import SwiftUI
import UniformTypeIdentifiers

/// The row of open notebooks above the library and the editor (like Goodnotes). Tap a tab to
/// show it, × to close it, hold for Close Other Tabs, and drag to reorder.
///
/// A horizontal `ScrollView` + `HStack`, not a `List` (see "Rules learned": lists swallow drops).
struct TabStrip: View {
    @Environment(WindowSession.self) private var session
    /// The tab being dragged, so drops from anywhere else (text, PDFs) are ignored.
    @State private var draggedTab: UUID?
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.tabs) { tab in
                        TabChip(
                            tab: tab, isActive: tab.id == session.activeTabID,
                            select: { select(tab) }, close: { close(tab) })
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
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: session.activeTabID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .alert("Could not close the tab", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(tab.title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .padding(.leading, 12)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close \(tab.title)")
        }
        .frame(minWidth: 110, minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color(.systemBackground) : Color(.secondarySystemFill)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
