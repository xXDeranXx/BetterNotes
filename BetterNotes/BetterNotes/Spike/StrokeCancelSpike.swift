import PencilKit
import SwiftUI
import UIKit

// THROWAWAY SPIKE (milestone 2, step 1). Delete after the result is in SPEC.md "Decided".
//
// Question: if a second gesture recognizer notices that the Pencil has been held still
// for 0.5 s, can it cancel PencilKit's stroke in progress cleanly (no flicker, no ink left)?

/// Watches touches without ever "recognizing", so it never steals touches from PencilKit.
/// A gesture recognizer is like an event listener that is told about every touch; this one
/// only listens. `onHold` fires when the touch has moved less than `tolerance` points for `holdTime`.
final class HoldWatcher: UIGestureRecognizer {
    var onHold: ((CGPoint) -> Void)?
    var holdTime: Duration = .milliseconds(500)
    var tolerance: CGFloat = 4

    private var anchor: CGPoint = .zero
    private var holdTask: Task<Void, Never>?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        anchor = touch.location(in: view)
        restartTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        if hypot(point.x - anchor.x, point.y - anchor.y) > tolerance {
            anchor = point
            restartTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish() }

    private func finish() {
        holdTask?.cancel()
        state = .failed  // tells UIKit we are done; the recognizer resets for the next touch
    }

    private func restartTimer() {
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: holdTime)
            guard !Task.isCancelled else { return }
            onHold?(anchor)
        }
    }
}

/// UIViewRepresentable wraps a UIKit view so SwiftUI can show it. SwiftUI calls
/// `makeUIView` once (like a React mount effect) and `updateUIView` when inputs change.
struct SpikeCanvas: UIViewRepresentable {
    @Binding var status: String

    func makeCoordinator() -> Coordinator { Coordinator(status: $status) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput  // the spike also has to work with a finger in the simulator
        canvas.backgroundColor = .white
        // In dark mode PencilKit draws a black pen as white, which is invisible on white paper.
        // Pages stay white in this app (SPEC), so the canvas always uses the light appearance.
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas

        let watcher = HoldWatcher(target: nil, action: nil)
        watcher.delegate = context.coordinator
        watcher.onHold = { [weak coordinator = context.coordinator] point in
            coordinator?.holdDetected(at: point)
        }
        canvas.addGestureRecognizer(watcher)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    /// The coordinator is the object that lives next to the UIKit view and receives its
    /// delegate callbacks (SwiftUI has no other place for them).
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var status: Binding<String>
        weak var canvas: PKCanvasView?
        private var holds = 0
        private var marker: UIView?

        init(status: Binding<String>) { self.status = status }

        // Lets HoldWatcher run at the same time as PencilKit's own recognizer.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func holdDetected(at point: CGPoint) {
            guard let canvas else { return }
            holds += 1
            let before = canvas.drawing.strokes.count

            // The experiment: switch PencilKit's recognizer off and on again. Disabling a
            // recognizer mid-gesture makes UIKit cancel it.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true

            showMarker(at: point, in: canvas)
            status.wrappedValue = "Hold #\(holds) at (\(Int(point.x)), \(Int(point.y))). Strokes before cancel: \(before). Checking…"

            // The cancelled stroke might still be delivered a moment later, so look again.
            let holdNumber = holds
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let canvas = self.canvas else { return }
                self.status.wrappedValue = "Hold #\(holdNumber): strokes before cancel \(before), 300 ms later \(canvas.drawing.strokes.count)."
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let strokes = canvasView.drawing.strokes
            let last = strokes.last.map { stroke in
                "last: \(stroke.path.count) points, \(Int(stroke.renderBounds.width))x\(Int(stroke.renderBounds.height)) pt"
            } ?? "none"
            status.wrappedValue = "Drawing changed: \(strokes.count) stroke(s) committed, \(last)."
        }

        /// A red ring where the hold was detected, standing in for the future shape preview layer.
        private func showMarker(at point: CGPoint, in view: UIView) {
            marker?.removeFromSuperview()
            let ring = UIView(frame: CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40))
            ring.layer.cornerRadius = 20
            ring.layer.borderColor = UIColor.red.cgColor
            ring.layer.borderWidth = 3
            ring.isUserInteractionEnabled = false
            view.addSubview(ring)
            marker = ring
        }
    }
}

struct StrokeCancelSpikeView: View {
    @State private var status = "Draw a line, then keep the pen still without lifting for 0.5 s."

    var body: some View {
        VStack(spacing: 0) {
            Text(status)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
            SpikeCanvas(status: $status)
        }
        .navigationTitle("Spike: cancel stroke")
        .navigationBarTitleDisplayMode(.inline)
    }
}
