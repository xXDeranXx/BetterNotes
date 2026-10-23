import SwiftUI

/// The text tool's options (M8): font, size, bold, italic and color of new text boxes. A box
/// that exists already changes through its own menu (select it, then Font, Font Size or Color),
/// and single words while typing (select them, then Bold or Italic, or Cmd+B and Cmd+I).
struct TextOptionsView: View {
    @Bindable var tools: ToolController

    private var settings: ToolSettings { tools.settings }

    /// The same font `TextBoxLayout` uses on the page, so the preview tells the truth.
    private func font(_ family: TextFont, size: Double, bold: Bool = false, italic: Bool = false) -> Font {
        Font(TextBoxLayout.font(family, size: size, bold: bold, italic: italic) as CTFont)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(TextFont.allCases, id: \.self) { family in
                    Button {
                        tools.settings.textFont = family
                    } label: {
                        Text(family.displayName)
                            .font(font(family, size: 15))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(family == settings.textFont ? Color.accentColor.opacity(0.15) : Color.clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(family == settings.textFont ? Color.accentColor : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(family == settings.textFont ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                Picker("Size", selection: $tools.settings.textFontSize) {
                    ForEach(ToolSettings.textFontSizes, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                styleToggle("B", label: "Bold", isOn: $tools.settings.textBold, bold: true)
                styleToggle("I", label: "Italic", isOn: $tools.settings.textItalic, italic: true)
            }
            Text("Aa Text")
                .font(font(settings.textFont, size: min(settings.textFontSize, 40), bold: settings.textBold, italic: settings.textItalic))
                .foregroundStyle(Color(hex: settings.textColorHex))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            Divider()
            ColorChooser(
                tools: tools,
                hex: Binding(get: { tools.settings.textColorHex }, set: { tools.settings.textColorHex = HexColor.normalized($0) ?? $0 }))
            Text("Tap the page to place a text box, or tap a text box to edit it. While typing, select words for Bold or Italic.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    private func styleToggle(_ letter: String, label: String, isOn: Binding<Bool>, bold: Bool = false, italic: Bool = false) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(letter)
                .font(font(.system, size: 17, bold: bold, italic: italic))
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn.wrappedValue ? Color.accentColor.opacity(0.2) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}
