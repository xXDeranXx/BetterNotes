import SwiftUI

/// The shape tool's options: which shape, solid / dashed / dotted, filled or a frame, and its
/// own color and width, with a live preview drawn from the same geometry as the real strokes.
struct ShapeOptionsView: View {
    @Bindable var tools: ToolController

    private var shape: ShapeSetting { tools.settings.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shapes").font(.headline)
            Picker("Shape", selection: $tools.settings.shape.kind) {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    Image(systemName: kind.symbol).accessibilityLabel(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Picker("Line", selection: $tools.settings.shape.lineStyle) {
                Text("Solid").tag(LineStyle.solid)
                Text("Dashed").tag(LineStyle.dashed)
                Text("Dotted").tag(LineStyle.dotted)
            }
            .pickerStyle(.segmented)
            Toggle("Fill", isOn: $tools.settings.shape.isFilled)
                .disabled(!shape.kind.canBeFilled)
            preview
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Slider(value: Binding(get: { shape.width }, set: { tools.settings.setShapeWidth($0) }),
                       in: ShapeSetting.widthRange)
                Image(systemName: "circle.fill").font(.system(size: 16))
                Text(String(format: "%.1f", shape.width)).monospacedDigit().font(.caption).frame(width: 36)
            }
            Divider()
            ColorChooser(tools: tools, hex: Binding(get: { shape.colorHex }, set: { tools.settings.setShapeColor($0) }))
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    /// The shape as it will be drawn, on a white page.
    private var preview: some View {
        let start = CGPoint(x: 100, y: 12), end = CGPoint(x: 188, y: 68)
        let outline = ShapeGeometry.outline(
            shape.kind, from: start, to: end, style: shape.lineStyle, width: CGFloat(shape.width), filled: shape.isFilled)
        let color = Color(hex: shape.colorHex)
        return RoundedRectangle(cornerRadius: 10)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .frame(height: 80)
            .overlay {
                ZStack {
                    if let fill = outline?.fill {
                        polyline([fill])
                            .stroke(color.opacity(ShapeGeometry.fillOpacity),
                                    style: StrokeStyle(lineWidth: ShapeGeometry.fillWidth, lineCap: .round, lineJoin: .round))
                    }
                    polyline(outline?.pieces ?? [])
                        .stroke(color, style: StrokeStyle(lineWidth: CGFloat(shape.width), lineCap: .round, lineJoin: .round))
                }
                .frame(width: 288, height: 80)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func polyline(_ pieces: [[CGPoint]]) -> Path {
        Path { path in
            for piece in pieces {
                guard let first = piece.first else { continue }
                path.move(to: first)
                if piece.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
                for point in piece.dropFirst() { path.addLine(to: point) }
            }
        }
    }
}
