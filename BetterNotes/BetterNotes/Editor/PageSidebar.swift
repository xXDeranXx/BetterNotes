import SwiftUI

/// One page's picture with its number. Used by the sidebar and the page grid.
struct PageThumbnailView: View {
    let page: PageMeta
    let number: Int
    let thumbnails: ThumbnailStore
    var isHighlighted = false

    // The picture arrives later (it is rendered in the background); until then the page is a
    // white rectangle of the right shape, so the list does not jump around.
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.white
                if let image { Image(uiImage: image).resizable().scaledToFit() }
            }
            .aspectRatio(page.size.width / page.size.height, contentMode: .fit)
            .overlay(Rectangle().stroke(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isHighlighted ? 3 : 1))
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
        }
        // The key changes when the page's ink or rotation changes; SwiftUI then cancels the old
        // render and starts a new one, which also waits out a burst of strokes.
        .task(id: thumbnails.key(for: page)) {
            if let rendered = await thumbnails.image(for: page) { image = rendered }
        }
    }
}

/// The strip of page pictures at the side of the editor: tap to jump, long-press for the
/// page menu, and a button that adds a page at the end.
struct PageSidebar: View {
    let notebook: Notebook
    let thumbnails: ThumbnailStore
    let navigator: PageNavigator
    let actions: PageActions

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only the pictures on screen are created (and rendered), which keeps a
                // 300-page notebook light. (A ScrollView, not a List: see SPEC, M3.)
                LazyVStack(spacing: 14) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailView(
                            page: page, number: index + 1, thumbnails: thumbnails,
                            isHighlighted: navigator.currentPageID == page.id
                        )
                        .id(page.id)
                        .contentShape(Rectangle())
                        .onTapGesture { navigator.goTo(page.id) }
                        .contextMenu { PageMenu(page: page, actions: actions) }
                    }
                    AddPageButton(actions: actions)
                }
                .padding(12)
            }
            .onChange(of: navigator.currentPageID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 168)
        .background(.regularMaterial)
    }
}

/// "Add page" at the end: a tap adds a page like the last one; press and hold to choose the template.
struct AddPageButton: View {
    let actions: PageActions

    var body: some View {
        Menu {
            ForEach(PageTemplate.choosable, id: \.self) { template in
                Button(template.menuName, systemImage: template.menuIcon) {
                    actions.addPageAtEnd(template: template)
                }
            }
        } label: {
            Label("Add Page", systemImage: "plus.square")
                .frame(maxWidth: .infinity)
        } primaryAction: {
            actions.addPageAtEnd()
        }
        .buttonStyle(.bordered)
    }
}

/// The menu of one page (long-press in the sidebar, and in the grid).
struct PageMenu: View {
    let page: PageMeta
    let actions: PageActions

    var body: some View {
        Menu("Insert Page Before", systemImage: "arrow.up.doc") {
            ForEach(PageTemplate.choosable, id: \.self) { template in
                Button(template.menuName, systemImage: template.menuIcon) {
                    actions.insertPage(template: template, relativeTo: page.id, after: false)
                }
            }
        }
        Menu("Insert Page After", systemImage: "arrow.down.doc") {
            ForEach(PageTemplate.choosable, id: \.self) { template in
                Button(template.menuName, systemImage: template.menuIcon) {
                    actions.insertPage(template: template, relativeTo: page.id, after: true)
                }
            }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { actions.duplicate([page.id]) }
        Button("Rotate", systemImage: "rotate.right") { actions.rotate([page.id], by: 90) }
        Button("Delete", systemImage: "trash", role: .destructive) { actions.delete([page.id]) }
    }
}
