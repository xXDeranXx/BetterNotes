import SwiftUI
import UniformTypeIdentifiers

/// The row of open notebooks above the library and the editor, laid out like Goodnotes and a
/// browser's tab bar: the house (library) on the left, then small tabs that share the width
/// up to `maximumTabWidth`. The active tab has the color of the editor's top bar (see
/// `AppTheme`), so tab and bar look like one piece. Tap a tab to show it, × to
/// close it, hold for Close Other Tabs, and drag to reorder.
///
/// A horizontal `ScrollView` + `HStack`, not a `List` (see "Rules learned": lists swallow drops).
struct TabStrip: View {
    /// Tabs shrink from the widest to the narrowest as more open; below that the strip scrolls.
    static let maximumTabWidth: CGFloat = 220
    static let minimumTabWidth: CGFloat = 120

    @Environment(WindowSession.self) private var session
    @AppStorage(AppTheme.settingKey) private var theme = AppTheme.system
    /// The tab being dragged, so drops from anywhere else (text, PDFs) are ignored.
    @State private var draggedTab: UUID?
    @State private var errorMessage: String?
    /// The tab being renamed, and the name typed so far (an alert, not a popover: the Pencil
    /// would write into a text field in a popover with Scribble).
    @State private var renaming: NotebookTab?
    @State private var newName = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            homeButton
            GeometryReader { geometry in
                let count = CGFloat(max(session.tabs.count, 1))
                let width = min(Self.maximumTabWidth, max(Self.minimumTabWidth, geometry.size.width / count))
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
        .padding(.top, 6)
        .frame(height: 38)
        .background(theme.stripColor(colorScheme).ignoresSafeArea(edges: .top))  // also behind the status bar
        .alert("Rename Notebook", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let tab = renaming else { return }
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != tab.title else { return }
                Task {
                    do {
                        try await session.renameTab(tab.id, to: name)
                    } catch {
                        errorMessage = "\"\(tab.title)\" could not be renamed: \(error.localizedDescription)"
                    }
                }
            }
        }
        .alert("Could not change the tab", isPresented: Binding(
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
        .font(.callout.weight(.medium))
        .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)
        .frame(width: 46, height: 32)
    }

    private func chip(for tab: NotebookTab, at index: Int) -> some View {
        let isActive = tab.id == session.activeTabID
        // A thin line between two inactive tabs, as in Goodnotes.
        let next = session.tabs.indices.contains(index + 1) ? session.tabs[index + 1].id : nil
        let showsSeparator = !isActive && next != nil && next != session.activeTabID
        return TabChip(
            tab: tab, theme: theme, barColor: theme.barColor(colorScheme), isActive: isActive, showsSeparator: showsSeparator,
            select: { select(tab) }, close: { close(tab) })
            .id(tab.id)
            .contextMenu {
                Button("Rename…", systemImage: "pencil") {
                    newName = tab.title
                    renaming = tab
                }
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
    let theme: AppTheme
    let barColor: Color
    let isActive: Bool
    let showsSeparator: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.footnote.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .padding(.trailing, 2)
            .accessibilityLabel("Close \(tab.title)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? barColor : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(alignment: .trailing) {
            // A plain Divider would be horizontal here (it follows the stack around it).
            if showsSeparator { Rectangle().fill(theme.secondaryText.opacity(0.4)).frame(width: 1, height: 14) }
        }
        .opacity(tab.isDetached ? 0.5 : 1)  // the library is moving its notebook
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
