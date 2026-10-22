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
    /// The page's rotation when `image` was drawn. When the page is turned, the old picture
    /// is turned on screen straight away (see `turn`), so there is no squeezed or blank
    /// moment while the new, sharp picture is being rendered.
    @State private var imageRotation = 0

    /// Degrees (-180...180) the old picture still has to be turned to match the page now.
    private var turn: Int {
        var degrees = (page.rotation - imageRotation) % 360
        if degrees < 0 { degrees += 360 }
        return degrees > 180 ? degrees - 360 : degrees
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.white
                if let image {
                    GeometryReader { box in
                        // Before turning, the old picture has the old (swapped) shape.
                        let sideways = turn % 180 != 0
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(width: sideways ? box.size.height : box.size.width,
                                   height: sideways ? box.size.width : box.size.height)
                            .rotationEffect(.degrees(Double(turn)))
                            .position(x: box.size.width / 2, y: box.size.height / 2)
                    }
                }
            }
            .aspectRatio(page.size.width / page.size.height, contentMode: .fit)
            .overlay(Rectangle().stroke(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isHighlighted ? 3 : 1))
            .animation(.easeInOut(duration: 0.3), value: page.rotation)
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
        }
        // The key changes when the page's ink or rotation changes; SwiftUI then cancels the old
        // render and starts a new one, which also waits out a burst of strokes.
        .task(id: thumbnails.key(for: page)) {
            let rotation = page.rotation
            if let rendered = await thumbnails.image(for: page) {
                if image == nil {
                    withAnimation(.easeIn(duration: 0.2)) {  // the first picture fades in
                        image = rendered
                        imageRotation = rotation
                    }
                } else {
                    // The new picture looks like the turned old one, so swap without animating.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        image = rendered
                        imageRotation = rotation
                    }
                }
            }
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
    @Binding var insertKind: InsertKind?

    /// The page a drag is currently over, to show where it would land.
    @State private var dropTargetID: UUID?

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
                        // A bar above the page shows where a dragged page would be dropped.
                        .overlay(alignment: .top) {
                            if dropTargetID == page.id {
                                Capsule().fill(Color.accentColor).frame(height: 4).offset(y: -9)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { navigator.goTo(page.id) }
                        // Drag to reorder, like in the grid (same rule: see `PageReorder`).
                        .draggable(page.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                            actions.drop(dragged, selection: [], onto: page.id)
                            return true
                        } isTargeted: { isTargeted in
                            if isTargeted { dropTargetID = page.id } else if dropTargetID == page.id { dropTargetID = nil }
                        }
                        .contextMenu { PageMenu(page: page, actions: actions) }
                    }
                    AddPageButton(actions: actions, insertKind: $insertKind)
                }
                .padding(12)
                // Pages slide into their new places after an insert, delete or reorder.
                .animation(.easeInOut(duration: 0.25), value: notebook.pages.map(\.id))
            }
            .onChange(of: navigator.currentPageID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 168)
        .background(.regularMaterial)
    }
}

/// The plus: a tap adds a page like the last one at the end; press and hold opens the menu
/// with the templates (blank, lined, grid, dotted) and the ways to insert existing pages
/// (a PDF, a photo, an image file).
struct AddPageButton: View {
    let actions: PageActions
    @Binding var insertKind: InsertKind?

    var body: some View {
        Menu {
            Section("New page") {
                ForEach(PageTemplate.choosable, id: \.self) { template in
                    Button(template.menuName, systemImage: template.menuIcon) {
                        actions.addPageAtEnd(template: template)
                    }
                }
            }
            Section("Insert") {
                InsertMenuItems(kind: $insertKind)
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
        Button("Rotate", systemImage: "rotate.right") { withAnimation { actions.rotate([page.id], by: 90) } }
        Button("Delete", systemImage: "trash", role: .destructive) { actions.delete([page.id]) }
    }
}
