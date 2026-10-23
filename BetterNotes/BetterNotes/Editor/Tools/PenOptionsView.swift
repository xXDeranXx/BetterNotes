import PencilKit
import SwiftUI

/// Color and width of one pen: a width slider with a live preview, favorite colors, a hex
/// field, the system color picker, and saved pen presets.
struct PenOptionsView: View {
    @Bindable var tools: ToolController
    let kind: PenKind
    private var setting: PenSetting { tools.settings.setting(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.displayName).font(.headline)
            preview
            widthSlider
            Divider()
            colorSection
            Divider()
            presetSection
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    /// A stroke as the pen will draw it: the chosen color at the chosen width.
    private var preview: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .frame(height: 56)
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 24, y: 28))
                    path.addCurve(to: CGPoint(x: 276, y: 28), control1: CGPoint(x: 90, y: 4), control2: CGPoint(x: 190, y: 52))
                }
                .stroke(Color(hex: setting.colorHex).opacity(kind == .marker ? 0.45 : 1),
                        style: StrokeStyle(lineWidth: CGFloat(setting.width), lineCap: kind == .marker ? .butt : .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var widthSlider: some View {
        let range = kind.widthRange
        return HStack {
            Image(systemName: "circle.fill").font(.system(size: 6))
            Slider(value: Binding(get: { setting.width }, set: { tools.settings.setWidth($0, for: kind) }), in: range)
            Image(systemName: "circle.fill").font(.system(size: 16))
            Text(String(format: "%.1f", setting.width)).monospacedDigit().font(.caption).frame(width: 36)
        }
    }

    private var colorSection: some View {
        ColorChooser(tools: tools, hex: Binding(get: { setting.colorHex }, set: { tools.settings.setColor($0, for: kind) }))
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Presets").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save as Preset", systemImage: "plus") { _ = tools.settings.addPresetFromCurrentPen() }
                    .font(.subheadline)
                    .disabled(tools.settings.presets.count >= ToolSettings.maxPresets)
            }
            if tools.settings.presets.isEmpty {
                Text("A preset remembers pen, color and width. Tap one to switch to it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tools.settings.presets) { preset in
                            Button { tools.settings.apply(preset) } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: preset.kind.symbol).foregroundStyle(Color(hex: preset.colorHex))
                                    Text("\(Int(preset.width))").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(width: 44, height: 44)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .contextMenu {
                                Button("Delete Preset", systemImage: "trash", role: .destructive) {
                                    tools.settings.removePreset(preset.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Eraser type and size.
struct EraserOptionsView: View {
    @Bindable var tools: ToolController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eraser").font(.headline)
            Picker("Eraser", selection: $tools.settings.eraserMode) {
                Text("Stroke").tag(EraserMode.stroke)
                Text("Precision").tag(EraserMode.pixel)
            }
            .pickerStyle(.segmented)
            if tools.settings.eraserMode == .pixel {
                HStack {
                    Circle().fill(.quaternary).frame(width: 10, height: 10)
                    Slider(
                        value: Binding(get: { tools.settings.eraserWidth }, set: { tools.settings.setEraserWidth($0) }),
                        in: ToolSettings.eraserWidthRange)
                    Circle().fill(.quaternary).frame(width: 30, height: 30)
                }
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1.5)
                    .frame(width: CGFloat(tools.settings.eraserWidth), height: CGFloat(tools.settings.eraserWidth))
                    .frame(maxWidth: .infinity, minHeight: 84)
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}

/// Where the toolbar sits, which pens it shows, and the gestures.
struct ToolbarSettingsView: View {
    @Bindable var tools: ToolController
    @AppStorage(DebugOverlay.settingKey) private var showsDebugOverlay = false
    @AppStorage(AppTheme.settingKey) private var theme = AppTheme.system

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    Picker("Toolbar", selection: $tools.settings.toolbarPosition) {
                        Text("Top").tag(ToolbarPosition.top)
                        Text("Left").tag(ToolbarPosition.leading)
                        Text("Right").tag(ToolbarPosition.trailing)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Pens on the toolbar") {
                    ForEach(tools.settings.enabledPens, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.symbol)
                    }
                    .onMove { tools.settings.movePen(from: $0, to: $1) }
                    .onDelete { offsets in
                        for kind in offsets.map({ tools.settings.enabledPens[$0] }) { tools.settings.setPen(kind, enabled: false) }
                    }
                    let hidden = PenKind.allCases.filter { !tools.settings.enabledPens.contains($0) }
                    if !hidden.isEmpty {
                        Menu("Add a Pen", systemImage: "plus") {
                            ForEach(hidden, id: \.self) { kind in
                                Button(kind.displayName, systemImage: kind.symbol) { tools.settings.setPen(kind, enabled: true) }
                            }
                        }
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Gestures") {
                    Toggle("Draw with a finger", isOn: $tools.settings.allowsFingerDrawing)
                    Toggle("Hold to snap shapes", isOn: $tools.settings.holdToSnapShapes)
                    Toggle("Hold to smooth curves", isOn: $tools.settings.holdToSmoothCurves)
                    Toggle("Left-handed (palette opens to the right)", isOn: $tools.settings.isLeftHanded)
                    Toggle("Two-finger tap = undo", isOn: $tools.settings.twoFingerTapUndoes)
                    Toggle("Three-finger tap = redo", isOn: $tools.settings.threeFingerTapRedoes)
                }
                Section {
                    Toggle("Use the system tool palette", isOn: $tools.settings.usesSystemToolPicker)
                } footer: {
                    Text("The system palette has more brushes but looks different. Switch back if the own toolbar misses something.")
                }
                // Temporary, removed together with the Debug folder.
                Section("Debug") {
                    Toggle("Show debug overlay", isOn: $showsDebugOverlay)
                }
            }
            .navigationTitle("Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
        }
        .frame(width: 360, height: 560)
        .presentationCompactAdaptation(.popover)
    }
}

/// Favorite colors, the system color picker and a hex field, for a pen or the shape tool.
struct ColorChooser: View {
    @Bindable var tools: ToolController
    @Binding var hex: String
    @State private var hexText = ""
    @State private var hexIsInvalid = false
    @State private var isEnteringHex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tools.settings.favoriteColors, id: \.self) { color in
                        Button { hex = color } label: { swatch(color) }
                            .contextMenu {
                                Button("Remove from Favorites", systemImage: "trash", role: .destructive) {
                                    tools.settings.removeFavorite(color)
                                }
                            }
                    }
                    Button {
                        tools.settings.addFavorite(hex)
                    } label: {
                        Image(systemName: "plus.circle").font(.title2)
                    }
                    .accessibilityLabel("Add current color to favorites")
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 10) {
                ColorPicker("Color", selection: Binding(
                    get: { Color(hex: hex) },
                    set: { hex = HexColor.hex(of: UIColor($0)) }),
                    supportsOpacity: false)
                    .labelsHidden()
                // No text field in the popover itself: with the Pencil near it, Scribble turned
                // taps and strokes into typed text and the colors could not be changed (iPad).
                Button {
                    hexText = hex
                    isEnteringHex = true
                } label: {
                    Label(hex, systemImage: "number").font(.body.monospaced())
                }
                .accessibilityLabel("Enter hex color")
                Spacer()
            }
        }
        .alert("Hex Color", isPresented: $isEnteringHex) {
            TextField("#RRGGBB", text: $hexText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Set", action: applyHex)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hexIsInvalid ? "That is not a color. Use six hex digits, for example #1E5BFF." : "Six hex digits, for example #1E5BFF.")
        }
    }

    private func swatch(_ color: String) -> some View {
        Circle()
            .fill(Color(hex: color))
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
            .overlay {
                if color == hex {
                    Image(systemName: "checkmark").font(.caption.bold())
                        .foregroundStyle(HexColor.color(color).map(isDark) == true ? .white : .black)
                }
            }
    }

    private func isDark(_ color: UIColor) -> Bool {
        var white: CGFloat = 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        white = 0.299 * r + 0.587 * g + 0.114 * b
        return white < 0.5
    }

    private func applyHex() {
        if let normalized = HexColor.normalized(hexText) {
            hex = normalized
            hexIsInvalid = false
        } else {
            hexIsInvalid = true
            // Show the dialog again with the hint (an alert closes after any button).
            DispatchQueue.main.async { isEnteringHex = true }
        }
    }
}
