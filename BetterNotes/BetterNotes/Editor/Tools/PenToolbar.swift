import PencilKit
import SwiftUI

/// The toolbar floating over the page (SPEC, M7a): pens, eraser, lasso, ruler. It sits at the
/// top or at a side of the editor, can be collapsed to one small button, and follows the
/// settings in `ToolController`.
struct PenToolbar: View {
    @Bindable var tools: ToolController
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

    private var expanded: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
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
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4, y: 1)
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: isVertical ? 28 : 1, height: isVertical ? 1 : 28)
    }

    private func icon(_ symbol: String, isSelected: Bool, tint: Color = .primary) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 12))
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
