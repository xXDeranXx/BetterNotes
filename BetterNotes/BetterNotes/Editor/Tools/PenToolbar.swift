import PencilKit
import SwiftUI

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
    @State private var popover: Popover?

    private enum Popover: Hashable { case pen(PenKind), eraser, shape, settings }

    private var isVertical: Bool { tools.settings.toolbarPosition != .top }

    var body: some View {
        Group {
            if tools.settings.isToolbarCollapsed {
                collapsed
            } else {
                expanded
            }
        }
        .padding(8)
        .animation(.easeInOut(duration: 0.2), value: tools.settings.isToolbarCollapsed)
        .animation(.easeInOut(duration: 0.2), value: tools.settings.toolbarPosition)
    }

    private var collapsed: some View {
        Button {
            tools.settings.isToolbarCollapsed = false
        } label: {
            Image(systemName: collapsedSymbol)
                .foregroundStyle(currentColor)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 3, y: 1)
        }
        .accessibilityLabel("Show tools")
    }

    private var collapsedSymbol: String {
        switch tools.settings.selected {
        case .pen(let kind): kind.symbol
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .shape: tools.settings.shape.kind.symbol
        }
    }

    private var currentColor: Color {
        switch tools.settings.selected {
        case .pen: Color(hex: tools.currentPenSetting.colorHex)
        case .shape: Color(hex: tools.settings.shape.colorHex)
        case .eraser, .lasso: .primary
        }
    }

    // MARK: Automatic size

    static let largestButton: CGFloat = 44
    /// Smaller is hard to hit with a finger; below this the toolbar scrolls instead.
    static let smallestButton: CGFloat = 34
    private static let spacing: CGFloat = 6
    /// The outer padding (8 on each side) and the padding inside the background (8 on each side).
    private static let padding: CGFloat = 32

    /// Buttons: the pens, eraser, lasso, shapes, text box, image, ruler, presets, settings, hide.
    private var buttonCount: Int { tools.settings.enabledPens.count + 9 }
    /// Two dividers between the groups.
    private static let dividerCount = 2

    /// The length the expanded toolbar needs with buttons of `size`.
    private func length(buttonSize size: CGFloat) -> CGFloat {
        let items = buttonCount + Self.dividerCount
        return Self.padding + CGFloat(buttonCount) * size + CGFloat(Self.dividerCount) + CGFloat(items - 1) * Self.spacing
    }

    /// As big as fits, between `smallestButton` and `largestButton`.
    private var buttonSize: CGFloat {
        guard availableLength.isFinite else { return Self.largestButton }
        let fixed = length(buttonSize: 0)
        let fitting = (availableLength - fixed) / CGFloat(buttonCount)
        return min(max(fitting.rounded(.down), Self.smallestButton), Self.largestButton)
    }

    private var needsScrolling: Bool { length(buttonSize: buttonSize) > availableLength }

    private var expanded: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: Self.spacing)) : AnyLayout(HStackLayout(spacing: Self.spacing))
        let content = layout {
            buttons
        }
        .padding(8)
        return Group {
            if needsScrolling {
                ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) { content }
                    // The scroll view takes what is left after the outer padding.
                    .frame(maxWidth: isVertical ? nil : availableLength - 16, maxHeight: isVertical ? availableLength - 16 : nil)
            } else {
                content
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4, y: 1)
    }

    @ViewBuilder private var buttons: some View {
            ForEach(tools.settings.enabledPens, id: \.self) { kind in
                penButton(kind)
            }
            divider
            eraserButton
            toolButton(.lasso, symbol: "lasso", label: "Lasso")
            shapeButton
            // Text boxes come with milestone 8 (objects on pages).
            icon("character.textbox", isSelected: false)
                .opacity(0.35)
                .accessibilityLabel("Text box (coming later)")
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
            .foregroundStyle(tint)
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
                .overlay(alignment: .bottom) {
                    Capsule().fill(Color(hex: tools.settings.setting(for: kind).colorHex))
                        .frame(width: 18, height: 4).offset(y: -2)
                        .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                }
        }
        .accessibilityLabel(kind.displayName)
        .popover(isPresented: binding(for: .pen(kind))) { PenOptionsView(tools: tools, kind: kind) }
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
        }
        .accessibilityLabel("Shapes")
        .popover(isPresented: binding(for: .shape)) { ShapeOptionsView(tools: tools) }
    }

    private func toolButton(_ choice: ToolChoice, symbol: String, label: String) -> some View {
        Button { tools.select(choice) } label: { icon(symbol, isSelected: tools.settings.selected == choice) }
            .accessibilityLabel(label)
    }

    /// Puts an image on the page on screen (M8).
    private var imageMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { onInsertImage(.photos) }
            Button("Files", systemImage: "folder") { onInsertImage(.files) }
            // Not disabled when the clipboard is empty: the menu is built before it opens, so
            // that state could be out of date. Pasting explains it instead.
            Button("Paste", systemImage: "doc.on.clipboard") { onInsertImage(.clipboard) }
        } label: {
            icon("photo", isSelected: false)
        }
        .accessibilityLabel("Insert image")
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
