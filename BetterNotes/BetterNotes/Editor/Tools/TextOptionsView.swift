import SwiftUI

/// The text tool's options (M8): font size and color of new text boxes. A box that exists
/// already changes through its own menu (select it, then Font Size or Color).
struct TextOptionsView: View {
    @Bindable var tools: ToolController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text").font(.headline)
            Picker("Size", selection: $tools.settings.textFontSize) {
                ForEach(ToolSettings.textFontSizes, id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            .pickerStyle(.menu)
            Text("Aa Text")
                .font(.system(size: min(tools.settings.textFontSize, 40)))
                .foregroundStyle(Color(hex: tools.settings.textColorHex))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            Divider()
            ColorChooser(
                tools: tools,
                hex: Binding(get: { tools.settings.textColorHex }, set: { tools.settings.textColorHex = HexColor.normalized($0) ?? $0 }))
            Text("Tap the page to place a text box, or tap a text box to edit it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }
}
