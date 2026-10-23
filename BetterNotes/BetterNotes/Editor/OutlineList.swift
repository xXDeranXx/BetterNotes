import SwiftUI

/// The sidebar's Outline tab: the notebook's outline in page order, nested by level. Tap an entry
/// to go to its page; the entry of the page on screen is highlighted. Long-press for Rename,
/// Indent, Outdent and Delete. An imported PDF's outline is set up the first time this shows
/// (its own bookmarks, or titles guessed from its text; see `Notebook.setUpOutlineIfNeeded`).
struct OutlineList: View {
    let notebook: Notebook
    let navigator: PageNavigator
    /// Opens the "Add to Outline" dialog for a page (it lives in `PageSidebar`).
    let addToOutline: (UUID) -> Void

    @State private var collapsed: Set<UUID> = []
    @State private var renaming: OutlineEntry?
    @State private var renameText = ""
    @State private var isGenerating = false
    @State private var message: String?

    private var hasPDFPages: Bool { notebook.pages.contains { $0.template == .pdf } }

    var body: some View {
        let entries = notebook.visibleOutline
        let pageIDs = notebook.pages.map(\.id)
        let current = Outline.current(in: entries, pageIDs: pageIDs, currentPageID: navigator.currentPageID)
        let hidden = Outline.hiddenByCollapse(entries, collapsed: collapsed)
        VStack(spacing: 0) {
            if notebook.outline == nil || isGenerating {
                Spacer()
                ProgressView(isGenerating ? "Reading the pages…" : "")
                Spacer()
            } else if entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if !hidden.contains(entry.id) {
                                    row(entry, index: index, in: entries, pageIDs: pageIDs, isCurrent: entry.id == current)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: current) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            Divider()
            footer
        }
        .task { await notebook.setUpOutlineIfNeeded() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { notebook.renameOutlineEntry(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Outline", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func row(
        _ entry: OutlineEntry, index: Int, in entries: [OutlineEntry], pageIDs: [UUID], isCurrent: Bool
    ) -> some View {
        let hasChildren = Outline.hasChildren(at: index, in: entries)
        let pageNumber = (pageIDs.firstIndex(of: entry.pageID) ?? 0) + 1
        return HStack(spacing: 4) {
            // The disclosure arrow; an empty slot of the same width keeps titles lined up.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsed.contains(entry.id) { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(collapsed.contains(entry.id) ? 0 : 90))
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            .accessibilityLabel(collapsed.contains(entry.id) ? "Expand" : "Collapse")

            Text(entry.title)
                .font(entry.level == 0 ? .subheadline.weight(.semibold) : .subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(pageNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(entry.level) * 14)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isCurrent ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { navigator.goTo(entry.pageID) }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                renameText = entry.title
                renaming = entry
            }
            Button("Indent", systemImage: "increase.indent") { notebook.indentOutlineEntry(entry.id, by: 1) }
                .disabled(entry.level >= Outline.maximumLevel(of: entry.id, in: entries))
            Button("Outdent", systemImage: "decrease.indent") { notebook.indentOutlineEntry(entry.id, by: -1) }
                .disabled(entry.level == 0)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { notebook.deleteOutlineEntry(entry.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Outline")
                .font(.headline)
            Text("Add the page on screen with the button below, or long-press a page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if let page = navigator.currentPageID ?? notebook.pages.first?.id { addToOutline(page) }
            } label: {
                Label("Add to Outline", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(notebook.outline == nil || isGenerating)  // the PDF's own titles come first
            Menu {
                if hasPDFPages {
                    Button("Generate from Text", systemImage: "text.magnifyingglass") { generate() }
                }
                Button("Clear Outline", systemImage: "trash", role: .destructive) { notebook.clearOutline() }
                    .disabled(notebook.visibleOutline.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Outline Options")
        }
        .padding(12)
    }

    private func generate() {
        isGenerating = true
        Task {
            let found = await notebook.regenerateOutlineFromText()
            isGenerating = false
            if found == 0 {
                message = "No titles were found. Scanned pages have no text to read; add entries by hand instead."
            }
        }
    }
}
