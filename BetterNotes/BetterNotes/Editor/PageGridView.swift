import SwiftUI

/// Full-screen overview of all pages (SPEC, "Page grid view"): tap a page to go there,
/// "Select" to pick several, drag pages to reorder, and buttons for the page operations.
/// Everything goes through `PageActions`, so each action is one undo step.
struct PageGridView: View {
    let notebook: Notebook
    let thumbnails: ThumbnailStore
    let navigator: PageNavigator
    let actions: PageActions
    let close: () -> Void

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    /// The page a drag is currently over, to show where it would land.
    @State private var dropTargetID: UUID?
    @State private var insertKind: InsertKind?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)]

    /// The selection without pages that no longer exist (after a delete, or an undo).
    private var selectedIDs: Set<UUID> { selection.intersection(notebook.pages.map(\.id)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                // A ScrollView with a lazy grid, not a List: only the visible cells are made,
                // and drag and drop behaves (see SPEC, M3).
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                        cell(for: page, number: index + 1)
                    }
                }
                .padding(20)
            }
            .navigationTitle(isSelecting ? "\(selectedIDs.count) selected" : "Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // New pages go after the last selected page, or at the end.
            .pageInsertion(kind: $insertKind, actions: actions, reveal: false) {
                let selected = selectedIDs
                guard let last = notebook.pages.lastIndex(where: { selected.contains($0.id) }) else {
                    return notebook.pages.count
                }
                return last + 1
            }
        }
    }

    private func cell(for page: PageMeta, number: Int) -> some View {
        let isSelected = selectedIDs.contains(page.id)
        return PageThumbnailView(page: page, number: number, thumbnails: thumbnails, isHighlighted: isSelected)
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .background(Circle().fill(.background).padding(2))
                        .padding(6)
                }
            }
            // A bar on the leading edge shows where a dragged page would be dropped.
            .overlay(alignment: .leading) {
                if dropTargetID == page.id {
                    Rectangle().fill(Color.accentColor).frame(width: 4).offset(x: -11)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if isSelected { selection.remove(page.id) } else { selection.insert(page.id) }
                } else {
                    navigator.goTo(page.id)
                    close()
                }
            }
            // The dragged item is the page's id as text; the drop side turns it back into an id.
            .draggable(page.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                actions.drop(dragged, selection: selectedIDs, onto: page.id)
                return true
            } isTargeted: { isTargeted in
                if isTargeted { dropTargetID = page.id } else if dropTargetID == page.id { dropTargetID = nil }
            }
            .contextMenu { PageMenu(page: page, actions: actions) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done", action: close)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { notebook.undoManager.undo() }
                .disabled(!notebook.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { notebook.undoManager.redo() }
                .disabled(!notebook.canRedo)
            Button(isSelecting ? "Cancel" : "Select") {
                isSelecting.toggle()
                selection = []
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if isSelecting {
                selectionButtons
            } else {
                AddPageButton(actions: actions)
                Spacer()
                Menu("Insert", systemImage: "doc.badge.plus") { InsertMenuItems(kind: $insertKind) }
            }
        }
    }

    @ViewBuilder
    private var selectionButtons: some View {
        let ids = selectedIDs
        let hasSelection = !ids.isEmpty
        Button("Duplicate", systemImage: "plus.square.on.square") {
            actions.duplicate(ids)
            selection = []
        }
        .disabled(!hasSelection)
        Spacer()
        Button("Rotate Left", systemImage: "rotate.left") { actions.rotate(ids, by: -90) }
            .disabled(!hasSelection)
        Button("Rotate Right", systemImage: "rotate.right") { actions.rotate(ids, by: 90) }
            .disabled(!hasSelection)
        Spacer()
        Menu("Insert", systemImage: "doc.badge.plus") { InsertMenuItems(kind: $insertKind) }
        Button("Delete", systemImage: "trash", role: .destructive) {
            actions.delete(ids)
            selection = []
        }
        .disabled(!hasSelection)
    }
}
