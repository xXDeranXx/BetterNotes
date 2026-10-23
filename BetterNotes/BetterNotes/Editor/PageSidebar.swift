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

    /// Width / height of the page before its own rotation. The slot the picture sits in has
    /// this shape and never changes when the page is turned, so turning a page moves nothing
    /// else in the sidebar or the grid (a slot that changed shape was laid out at its new size
    /// at once and made the picture jump).
    private var slotAspect: CGFloat {
        let unrotated = page.rotation % 180 == 0 ? page.size : page.size.landscape
        return unrotated.width / unrotated.height
    }

    /// The largest size with the given width / height that fits inside `box`.
    private func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        aspect >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
    }

    /// Goodnotes style: a page with slightly rounded corners and a soft shadow; the current or
    /// selected page gets a ring a little outside its edge.
    private static let corner: CGFloat = 4

    private var border: some View {
        RoundedRectangle(cornerRadius: Self.corner)
            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
    }

    private var ring: some View {
        RoundedRectangle(cornerRadius: Self.corner + 3)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .padding(-5)
            .opacity(isHighlighted ? 1 : 0)
    }

    /// The page's look: corners, a hairline, a shadow and the ring.
    private func pageStyle<Content: View>(_ content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Self.corner))
            .overlay(border)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .overlay(ring)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { slot in
                if let image {
                    // The picture keeps the size it had before the page was turned and is only
                    // scaled and rotated, never resized. Turned by 90 degrees it has to be
                    // scaled so that it fills the sideways shape inside the slot exactly.
                    let aspect = image.size.width / image.size.height
                    let now = fit(aspect: aspect, in: slot.size)
                    let sideways = turn % 180 != 0
                    let target = fit(aspect: sideways ? 1 / aspect : aspect, in: slot.size)
                    pageStyle(Image(uiImage: image)
                        .resizable()
                        .frame(width: now.width, height: now.height))
                        .scaleEffect(sideways ? target.width / now.height : 1)
                        .rotationEffect(.degrees(Double(turn)))
                        .position(x: slot.size.width / 2, y: slot.size.height / 2)
                } else {
                    // Until the picture arrives: a white page of the right shape.
                    let shape = fit(aspect: page.size.width / page.size.height, in: slot.size)
                    pageStyle(Color.white
                        .frame(width: shape.width, height: shape.height))
                        .position(x: slot.size.width / 2, y: slot.size.height / 2)
                }
            }
            .aspectRatio(slotAspect, contentMode: .fit)
            .animation(.easeInOut(duration: 0.3), value: page.rotation)
            // The number sits in a small capsule that fills with the accent color when highlighted.
            Text("\(number)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isHighlighted ? Color.white : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isHighlighted ? Color.accentColor : .clear, in: Capsule())
                .padding(.top, 4)
        }
        // The key changes when the page's ink or rotation changes; SwiftUI then cancels the old
        // render and starts a new one, which also waits out a burst of strokes.
        .task(id: thumbnails.key(for: page)) {
            let rotation = page.rotation
            if let rendered = await thumbnails.image(for: page) {
                // The new picture is ready long before the turn animation ends. Swapping
                // earlier would snap the old picture back to 0 degrees in the middle of the
                // turn, so wait until the turn is finished; both then look the same.
                if turn != 0 {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                }
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

/// The sidebar at the side of the editor, with two tabs (like Goodnotes): the page pictures
/// (tap to jump, long-press for the page menu, a button that adds a page at the end) and the
/// outline (see `OutlineList`).
struct PageSidebar: View {
    enum Mode: String { case pages, outline }

    let notebook: Notebook
    let thumbnails: ThumbnailStore
    let navigator: PageNavigator
    let actions: PageActions
    @Binding var insertKind: InsertKind?

    /// Remembered per window, like the sidebar's place in other apps.
    @SceneStorage("sidebarMode") private var mode = Mode.pages
    /// The page a drag is currently over, to show where it would land.
    @State private var dropTargetID: UUID?
    /// The page whose "Add to Outline" dialog is open.
    @State private var outlinePage: UUID?
    @State private var outlineTitle = ""

    static let width: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $mode) {
                Text("Pages").tag(Mode.pages)
                Text("Outline").tag(Mode.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            switch mode {
            case .pages: pageList
            case .outline:
                OutlineList(notebook: notebook, navigator: navigator) { addToOutline($0) }
            }
        }
        .frame(width: Self.width)
        .background(Color(.secondarySystemBackground))
        // A dialog, not a field in a popover: the Pencil's Scribble would type into that.
        .alert("Add to Outline", isPresented: Binding(
            get: { outlinePage != nil }, set: { if !$0 { outlinePage = nil } })
        ) {
            TextField("Title", text: $outlineTitle)
            Button("Add") {
                if let page = outlinePage {
                    let title = outlineTitle
                    Task { await notebook.addToOutline(title: title, pageID: page) }
                }
                outlinePage = nil
            }
            Button("Cancel", role: .cancel) { outlinePage = nil }
        } message: {
            Text("The entry points at this page and moves with it.")
        }
    }

    /// Opens the dialog for a page, with "Page N" as the suggested title.
    private func addToOutline(_ pageID: UUID) {
        let number = (notebook.pages.firstIndex { $0.id == pageID } ?? 0) + 1
        outlineTitle = "Page \(number)"
        outlinePage = pageID
    }

    private var pageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only the pictures on screen are created (and rendered), which keeps a
                // 300-page notebook light. (A ScrollView, not a List: see SPEC, M3.)
                LazyVStack(spacing: 16) {
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
                        .contextMenu {
                            PageMenu(page: page, actions: actions)
                            Button("Add to Outline…", systemImage: "list.bullet.indent") { addToOutline(page.id) }
                        }
                    }
                    AddPageButton(actions: actions, insertKind: $insertKind)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                // Pages slide into their new places after an insert, delete or reorder.
                .animation(.easeInOut(duration: 0.25), value: notebook.pages.map(\.id))
            }
            .onChange(of: navigator.currentPageID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .onAppear { if let id = navigator.currentPageID { proxy.scrollTo(id) } }
        }
    }
}

/// The plus: a tap opens the menu with the templates for a new page at the end (blank, lined,
/// grid, dotted) and the ways to insert existing pages (a PDF, a photo, an image file).
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
        // Only pages made from a template can change it; an imported PDF page is someone else's content.
        if page.template != .pdf {
            Menu("Change Template", systemImage: "square.grid.3x3.square") {
                ForEach(PageTemplate.choosable, id: \.self) { template in
                    Button(
                        template.menuName,
                        systemImage: template == page.template ? "checkmark" : template.menuIcon
                    ) {
                        actions.changeTemplate([page.id], to: template)
                    }
                }
            }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { actions.duplicate([page.id]) }
        Button("Rotate", systemImage: "rotate.right") { withAnimation { actions.rotate([page.id], by: 90) } }
        Button("Delete", systemImage: "trash", role: .destructive) { actions.delete([page.id]) }
    }
}
