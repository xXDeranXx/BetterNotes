import SwiftUI
import UIKit

extension View {
    /// Shows the debug panel over this window when the "Debug" switch in the toolbar settings
    /// is on. Must sit inside `.environment(session)`.
    func debugOverlay() -> some View {
        modifier(DebugOverlayModifier())
    }
}

enum DebugOverlay {
    /// The `UserDefaults` key of the on/off switch (`@AppStorage`).
    static let settingKey = "showsDebugOverlay"
}

private struct DebugOverlayModifier: ViewModifier {
    @AppStorage(DebugOverlay.settingKey) private var isOn = false
    @AppStorage("debugOverlayCorner") private var corner = Corner.bottomTrailing

    func body(content: Content) -> some View {
        content.overlay(alignment: corner.alignment) {
            if isOn {
                DebugPanel(corner: $corner)
                    .padding(12)
            }
        }
    }
}

nonisolated enum Corner: String {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    init(isTop: Bool, isLeading: Bool) {
        self = switch (isTop, isLeading) {
        case (true, true): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }

    /// The corner a drag of `translation` points moves the panel to: far enough sideways or up
    /// and down flips it to the other side.
    func moved(by translation: CGSize, threshold: CGFloat = 120) -> Corner {
        var top = isTop
        var leading = isLeading
        if translation.width > threshold { leading = false }
        if translation.width < -threshold { leading = true }
        if translation.height > threshold { top = false }
        if translation.height < -threshold { top = true }
        return Corner(isTop: top, isLeading: leading)
    }
}

/// The small panel. Tap it to fold it to one line, drag it to another corner. It takes touches
/// only on its own small frame.
private struct DebugPanel: View {
    @Binding var corner: Corner
    @Environment(WindowSession.self) private var session
    @State private var monitor = DebugMonitor.shared
    @State private var window = WindowReference()
    @State private var counters = WindowCounters()
    @State private var recorder: DebugRecorder?
    @State private var recordings: [URL] = []
    @State private var isFolded = false
    @State private var drag = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sample = monitor.sample {
                if isFolded {
                    Text("\(percent(sample.cpuPercent)) · \(megabytes(sample.memoryFootprint)) · \(fps(sample)) · \(sample.thermalState.debugName)")
                } else {
                    details(sample)
                }
            } else {
                Text("Measuring…")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if let sample = monitor.sample {
                Circle().fill(thermalColor(sample.thermalState)).frame(width: 8, height: 8).padding(5)
            }
        }
        .background(WindowReader(reference: window))
        .offset(drag)
        .onTapGesture { isFolded.toggle() }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    corner = corner.moved(by: value.translation)
                    drag = .zero
                }
        )
        .onAppear {
            monitor.start()
            recordings = DebugRecorder.recordings()
        }
        .onDisappear {
            monitor.stop()
            recorder = nil
        }
        .onChange(of: monitor.sample) { _, sample in
            counters = WindowCounters.read(in: window.view?.window, notebook: session.notebook)
            if let sample { recorder?.append(sample, counters: counters) }
        }
    }

    @ViewBuilder private func details(_ sample: DebugSample) -> some View {
        Text("CPU \(percent(sample.cpuPercent))   Thermal \(sample.thermalState.debugName)")
        Text("Memory \(megabytes(sample.memoryFootprint))" + (sample.availableMemory > 0 ? ", \(megabytes(sample.availableMemory)) left" : ""))
        Text("\(fps(sample)), worst frame \(String(format: "%.0f", sample.longestFrameMilliseconds)) ms")
        Text("Canvases \(counters.canvases), k \(String(format: "%.0f", counters.renderScale))"
            + (counters.loadedDrawings.map { "   Drawings \($0)/\(counters.pages ?? 0)" } ?? ""))
        HStack(spacing: 10) {
            Button(recorder == nil ? "Record" : "Stop \(elapsed(sample))", systemImage: recorder == nil ? "record.circle" : "stop.circle") {
                toggleRecording()
            }
            .tint(recorder == nil ? .red : .primary)
            Menu("Files", systemImage: "square.and.arrow.up") {
                ForEach(recordings, id: \.self) { url in
                    ShareLink(item: url) {
                        Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "debug-", with: ""))
                    }
                }
                if !recordings.isEmpty {
                    Divider()
                    Button("Delete All Recordings", systemImage: "trash", role: .destructive) {
                        DebugRecorder.deleteAll()
                        recordings = DebugRecorder.recordings()
                    }
                    .disabled(recorder != nil)
                }
            }
            .disabled(recordings.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding(.top, 2)
    }

    private func toggleRecording() {
        if recorder == nil {
            recorder = try? DebugRecorder()
        } else {
            recorder = nil  // closes the file
        }
        recordings = DebugRecorder.recordings()
    }

    private func elapsed(_ sample: DebugSample) -> String {
        let seconds = Int(sample.date.timeIntervalSince(recorder?.startDate ?? sample.date))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    private func megabytes(_ bytes: UInt64) -> String {
        let mb = DebugRecord.megabytes(bytes)
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    private func fps(_ sample: DebugSample) -> String { String(format: "%.0f fps", sample.framesPerSecond) }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}

/// Holds the panel's UIKit view weakly, so the panel can find its window.
@Observable private final class WindowReference {
    @ObservationIgnored weak var view: UIView?
}

private struct WindowReader: UIViewRepresentable {
    let reference: WindowReference

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        reference.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
