import SwiftUI

/// What the Pencil's squeeze and double tap open, like in Goodnotes: pick a tool, then a
/// color and width, without leaving the page. The full options of one pen (hex field,
/// presets) stay behind a tap on the selected pen in the toolbar.
struct QuickPaletteView: View {
    @Bindable var tools: ToolController

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tools.settings.enabledPens, id: \.self) { kind in
                    toolButton(
                        kind.displayName, symbol: kind.symbol, tint: Color(hex: tools.settings.setting(for: kind).colorHex),
                        isSelected: tools.settings.selected == .pen(kind)
                    ) { tools.select(.pen(kind)) }
                }
                toolButton("Eraser", symbol: "eraser", isSelected: tools.settings.selected == .eraser) {
                    tools.select(.eraser)
                }
                toolButton("Lasso", symbol: "lasso", isSelected: tools.settings.selected == .lasso) {
                    tools.select(.lasso)
                }
                toolButton("Shapes", symbol: tools.settings.shape.kind.symbol,
                           tint: Color(hex: tools.settings.shape.colorHex),
                           isSelected: tools.settings.selected == .shape) {
                    tools.select(.shape)
                }
                toolButton("Ruler", symbol: "ruler", isSelected: tools.isRulerActive) {
                    tools.isRulerActive.toggle()
                }
            }

            if case .pen(let kind) = tools.settings.selected {
                Divider()
                colors(for: kind)
                widthSlider(for: kind)
            } else if tools.settings.selected == .eraser {
                Divider()
                Picker("Eraser", selection: $tools.settings.eraserMode) {
                    Text("Stroke").tag(EraserMode.stroke)
                    Text("Precision").tag(EraserMode.pixel)
                }
                .pickerStyle(.segmented)
                if tools.settings.eraserMode == .pixel {
                    Slider(
                        value: Binding(get: { tools.settings.eraserWidth }, set: { tools.settings.setEraserWidth($0) }),
                        in: ToolSettings.eraserWidthRange)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func toolButton(
        _ label: String, symbol: String, tint: Color = .primary, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 52, height: 48)
                .background(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(label)
    }

    private func colors(for kind: PenKind) -> some View {
        let current = tools.settings.setting(for: kind).colorHex
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tools.settings.favoriteColors, id: \.self) { hex in
                    Button { tools.settings.setColor(hex, for: kind) } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: hex == current ? 3 : 0).padding(-4))
                    }
                    .accessibilityLabel("Color \(hex)")
                }
            }
            .padding(6)
        }
    }

    private func widthSlider(for kind: PenKind) -> some View {
        let setting = tools.settings.setting(for: kind)
        return HStack {
            Image(systemName: "circle.fill").font(.system(size: 6))
            Slider(value: Binding(get: { setting.width }, set: { tools.settings.setWidth($0, for: kind) }), in: kind.widthRange)
            Image(systemName: "circle.fill").font(.system(size: 16))
        }
    }
}
