import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// The toolbar floating over the page (SPEC, M7a): pens, eraser, lasso, ruler. It sits at the
/// top or at a side of the editor, can be collapsed to one small button, and follows the
/// settings in `ToolController`.
struct PenToolbar: View {
    @Bindable var tools: ToolController
    /// The image menu's choice (Photos, Files, clipboard); the editor screen handles it.
    var onInsertImage: (ImageSource) -> Void = { _ in }
    /// The length the toolbar may take along its direction (the editor's width at the top, its
    /// height at a side). The buttons shrink to fit it, and below the smallest size it scrolls.
    var availableLength: CGFloat = .infinity
    /// In the editor's top bar (toolbar at the top): flat, smaller buttons, icons in the bar's
    /// text color, the pen colors as marks under the icons.
    var isInBar = false
    /// The icons' color in the bar (white on a tinted theme, see `AppTheme.primaryText`).
    var barIconColor: Color = .primary
    @State private var popover: Popover?

    private enum Popover: Hashable { case pen(PenKind), eraser, shape, text, settings }

    private var isVertical: Bool { tools.settings.toolbarPosition != .top }

    var body: some View {
        Group {
            if tools.settings.isToolbarCollapsed {
                collapsed
            } else {
                expanded
            }
        }
        .padding(isInBar ? 0 : 8)
        .animation(.easeInOut(duration: 0.2), value: tools.settings.isToolbarCollapsed)
        .animation(.easeInOut(duration: 0.2), value: tools.settings.toolbarPosition)
    }

    private var collapsed: some View {
        Button {
            tools.settings.isToolbarCollapsed = false
        } label: {
            Image(systemName: collapsedSymbol)
                .foregroundStyle(isInBar ? barIconColor : currentColor)
                .frame(width: isInBar ? 34 : 44, height: isInBar ? 34 : 44)
                .background(isInBar ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: Circle())
                .shadow(radius: isInBar ? 0 : 3, y: 1)
        }
        .accessibilityLabel("Show tools")
    }

    private var collapsedSymbol: String {
        switch tools.settings.selected {
        case .pen(let kind): kind.symbol
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .select: Self.selectSymbol
        case .text: "character.textbox"
        case .shape: tools.settings.shape.kind.symbol
        }
    }

    private var currentColor: Color {
        switch tools.settings.selected {
        case .pen: Color(hex: tools.currentPenSetting.colorHex)
        case .shape: Color(hex: tools.settings.shape.colorHex)
        case .text: Color(hex: tools.settings.textColorHex)
        case .eraser, .lasso, .select: .primary
        }
    }

    // MARK: Automatic size

    static let largestButton: CGFloat = 44
    /// Smaller is hard to hit with a finger; below this the toolbar scrolls instead.
    static let smallestButton: CGFloat = 34
    /// In the top bar the buttons must fit its height.
    static let largestBarButton: CGFloat = 36
    static let smallestBarButton: CGFloat = 32
    private var spacing: CGFloat { isInBar ? 2 : 6 }
    /// The outer padding (8 on each side) and the padding inside the background (8 on each side);
    /// in the bar only 2 on each side.
    private var padding: CGFloat { isInBar ? 4 : 32 }

    /// Buttons: the pens, eraser, lasso, select, shapes, text box, image, ruler, presets, settings, hide.
    private var buttonCount: Int { tools.settings.enabledPens.count + 10 }

    static let selectSymbol = "hand.point.up.left"
    /// Two dividers between the groups.
    private static let dividerCount = 2

    /// The length the expanded toolbar needs with buttons of `size`.
    private func length(buttonSize size: CGFloat) -> CGFloat {
        let items = buttonCount + Self.dividerCount
        return padding + CGFloat(buttonCount) * size + CGFloat(Self.dividerCount) + CGFloat(items - 1) * spacing
    }

    /// As big as fits, between `smallestButton` and `largestButton`.
    private var buttonSize: CGFloat {
        let largest = isInBar ? Self.largestBarButton : Self.largestButton
        let smallest = isInBar ? Self.smallestBarButton : Self.smallestButton
        guard availableLength.isFinite else { return largest }
        let fixed = length(buttonSize: 0)
        let fitting = (availableLength - fixed) / CGFloat(buttonCount)
        return min(max(fitting.rounded(.down), smallest), largest)
    }

    private var needsScrolling: Bool { length(buttonSize: buttonSize) > availableLength }

    private var expanded: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        let content = layout {
            buttons
        }
        .padding(isInBar ? 2 : 8)
        return Group {
            if needsScrolling {
                ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) { content }
                    // The scroll view takes what is left after the outer padding.
                    .frame(maxWidth: isVertical ? nil : availableLength - (isInBar ? 0 : 16), maxHeight: isVertical ? availableLength - 16 : nil)
            } else {
                content
            }
        }
        .background(isInBar ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: isInBar ? 0 : 4, y: 1)
    }

    @ViewBuilder private var buttons: some View {
            ForEach(tools.settings.enabledPens, id: \.self) { kind in
                penButton(kind)
            }
            divider
            eraserButton
            toolButton(.lasso, symbol: "lasso", label: "Lasso")
            // PencilKit's lasso only selects ink, so images and text boxes have their own tool.
            toolButton(.select, symbol: Self.selectSymbol, label: "Select images and text")
            shapeButton
            textButton
            imageMenu
            Button {
                tools.isRulerActive.toggle()
            } label: {
                icon("ruler", isSelected: tools.isRulerActive)
            }
            .accessibilityLabel("Ruler")
            divider
            presetsMenu
            Button {
                popover = .settings
            } label: {
                icon("slider.horizontal.3", isSelected: false)
            }
            .accessibilityLabel("Toolbar settings")
            .popover(isPresented: binding(for: .settings)) { ToolbarSettingsView(tools: tools) }
            Button {
                tools.settings.isToolbarCollapsed = true
            } label: {
                icon(isVertical ? "chevron.up.chevron.down" : "chevron.up", isSelected: false)
            }
            .accessibilityLabel("Hide tools")
    }

    private var divider: some View {
        let long = (buttonSize * 0.64).rounded()
        return Rectangle().fill(.quaternary).frame(width: isVertical ? long : 1, height: isVertical ? 1 : long)
    }

    private func icon(_ symbol: String, isSelected: Bool, tint: Color = .primary) -> some View {
        let size = buttonSize
        return Image(systemName: symbol)
            .font(size >= 40 ? .title3 : .body)
            // In the bar the ink color could vanish on the bar's color (black on blue); the
            // color is shown as a mark under the icon instead (see `colorMark`).
            .foregroundStyle(isInBar ? barIconColor : tint)
            .frame(width: size, height: size)
            .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: size * 0.27))
            .contentShape(Rectangle())
    }

    /// Tapping a pen selects it; tapping the selected pen again opens its color and width.
    private func penButton(_ kind: PenKind) -> some View {
        let isSelected = tools.settings.selected == .pen(kind)
        return Button {
            if isSelected { popover = .pen(kind) } else { tools.select(.pen(kind)) }
        } label: {
            icon(kind.symbol, isSelected: isSelected, tint: Color(hex: tools.settings.setting(for: kind).colorHex))
                .overlay(alignment: .bottom) { colorMark(tools.settings.setting(for: kind).colorHex) }
        }
        .accessibilityLabel(kind.displayName)
        .popover(isPresented: binding(for: .pen(kind))) { PenOptionsView(tools: tools, kind: kind) }
    }

    /// A small bar in the pen's color under its icon.
    private func colorMark(_ hex: String) -> some View {
        Capsule().fill(Color(hex: hex))
            .frame(width: 18, height: 4).offset(y: -2)
            .overlay(Capsule().strokeBorder(.white.opacity(isInBar ? 0.5 : 0), lineWidth: 0.5).offset(y: -2))
            .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5).offset(y: -2))
    }

    private var eraserButton: some View {
        let isSelected = tools.settings.selected == .eraser
        return Button {
            if isSelected { popover = .eraser } else { tools.select(.eraser) }
        } label: {
            icon("eraser", isSelected: isSelected)
        }
        .accessibilityLabel("Eraser")
        .popover(isPresented: binding(for: .eraser)) { EraserOptionsView(tools: tools) }
    }

    /// Tapping selects the shape tool; tapping it again opens shape, line style, fill, color and width.
    private var shapeButton: some View {
        let isSelected = tools.settings.selected == .shape
        return Button {
            if isSelected { popover = .shape } else { tools.select(.shape) }
        } label: {
            icon(tools.settings.shape.kind.symbol, isSelected: isSelected, tint: Color(hex: tools.settings.shape.colorHex))
                .overlay(alignment: .bottom) { if isInBar { colorMark(tools.settings.shape.colorHex) } }
        }
        .accessibilityLabel("Shapes")
        .popover(isPresented: binding(for: .shape)) { ShapeOptionsView(tools: tools) }
    }

    private func toolButton(_ choice: ToolChoice, symbol: String, label: String) -> some View {
        Button { tools.select(choice) } label: { icon(symbol, isSelected: tools.settings.selected == choice) }
            .accessibilityLabel(label)
    }

    /// Tapping selects the text tool (tap the page to place a box); tapping it again opens the
    /// font size and color for new boxes.
    private var textButton: some View {
        let isSelected = tools.settings.selected == .text
        return Button {
            if isSelected { popover = .text } else { tools.select(.text) }
        } label: {
            icon("character.textbox", isSelected: isSelected, tint: Color(hex: tools.settings.textColorHex))
                .overlay(alignment: .bottom) { if isInBar { colorMark(tools.settings.textColorHex) } }
        }
        .accessibilityLabel("Text box")
        .popover(isPresented: binding(for: .text)) { TextOptionsView(tools: tools) }
    }

    /// Puts an image on the page on screen (M8).
    private var imageMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { onInsertImage(.photos) }
            Button("Files", systemImage: "folder") { onInsertImage(.files) }
            // The system's own Paste button: reading the clipboard through it never shows the
            // "Allow Paste?" question (a plain button that reads the clipboard does). It is
            // greyed out by the system when there is no image to paste.
            PasteButton(supportedContentTypes: [.image]) { providers in
                guard let provider = providers.first else { return }
                Self.loadImageData(from: provider) { data in
                    Task { @MainActor in
                        if let data { onInsertImage(.pasted(data)) } else { onInsertImage(.unreadablePaste) }
                    }
                }
            }
        } label: {
            icon("photo", isSelected: false)
        }
        .accessibilityLabel("Insert image")
    }

    /// The pasted image's bytes, preferring PNG (screenshots stay crisp), then JPEG, then any image.
    private nonisolated static func loadImageData(from provider: NSItemProvider, completion: @escaping @Sendable (Data?) -> Void) {
        let types = [UTType.png, .jpeg, .heic, .image].map(\.identifier)
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            completion(nil)
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in completion(data) }
    }

    /// Saved pens: one tap switches to that exact pen.
    private var presetsMenu: some View {
        Menu {
            if tools.settings.presets.isEmpty {
                Text("No presets yet. Open a pen and choose Save as Preset.")
            }
            ForEach(tools.settings.presets) { preset in
                Button {
                    tools.settings.apply(preset)
                } label: {
                    Label("\(preset.kind.displayName) · \(Int(preset.width)) pt · \(preset.colorHex)", systemImage: preset.kind.symbol)
                }
            }
        } label: {
            icon("circle.grid.2x2", isSelected: false)
        }
        .accessibilityLabel("Pen presets")
    }

    private func binding(for target: Popover) -> Binding<Bool> {
        Binding(get: { popover == target }, set: { if !$0 && popover == target { popover = nil } })
    }
}

