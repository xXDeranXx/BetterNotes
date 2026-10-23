import Observation
import PencilKit
import SwiftUI
import UIKit

// Whiteboard spike (see docs/DECISIONS.md, "Whiteboard, design" and "Whiteboard spike").
// Temporary: measures memory, heat and frame rate of one big PKCanvasView with a lot of ink on
// the iPad, with the debug overlay. Nothing is saved. To remove it, delete `Spike/`, the
// "Whiteboard Spike" item in the library's "+" menu, `showsWhiteboardSpike` in `WindowSession`
// and its branch in `RootView`.

/// What the spike's top row shows.
@Observable
final class WhiteboardSpikeState {
    var strokeCount = 0
    var pointCount = 0
    var zoom: CGFloat = 1
    /// How long the last "+1000 strokes" took to put on the canvas.
    var lastAddMilliseconds: Int?
}

struct WhiteboardSpikeView: View {
    let close: () -> Void
    @State private var state = WhiteboardSpikeState()
    @State private var board = WhiteboardSpikeBoard()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Close", action: close)
                Divider().frame(height: 24)
                Button("+1000 Strokes", systemImage: "scribble.variable") { board.controller?.addStrokes(1000) }
                Button("Clear", systemImage: "trash", role: .destructive) { board.controller?.clear() }
                Button("Fit All", systemImage: "arrow.down.right.and.arrow.up.left") { board.controller?.zoomToFitInk() }
                Spacer()
                Text(status)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(.secondarySystemBackground))
            WhiteboardSpikeCanvas(state: state, board: board)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var status: String {
        var parts = [
            "\(state.strokeCount) strokes", "\(state.pointCount / 1000)k points",
            String(format: "zoom %.2f", state.zoom),
        ]
        if let ms = state.lastAddMilliseconds { parts.append("last add \(ms) ms") }
        return parts.joined(separator: " · ")
    }
}

/// Lets the SwiftUI buttons reach the UIKit controller.
@Observable
final class WhiteboardSpikeBoard {
    @ObservationIgnored weak var controller: WhiteboardSpikeController?
}

struct WhiteboardSpikeCanvas: UIViewControllerRepresentable {
    let state: WhiteboardSpikeState
    let board: WhiteboardSpikeBoard

    func makeUIViewController(context: Context) -> WhiteboardSpikeController {
        let controller = WhiteboardSpikeController(state: state)
        board.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: WhiteboardSpikeController, context: Context) {}
}

/// One `PKCanvasView` as its own scroll view: a 10000 x 10000 pt board, starting in the middle.
/// PencilKit draws only what is on screen and stays sharp at every zoom by itself.
final class WhiteboardSpikeController: UIViewController, PKCanvasViewDelegate {
    static let boardSize = CGSize(width: 10_000, height: 10_000)

    private let state: WhiteboardSpikeState
    private let canvas = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private var batches = 0
    private var didCenter = false

    init(state: WhiteboardSpikeState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light  // ink as on white paper (see "Rules learned")
        canvas.contentSize = Self.boardSize
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 5
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput  // the simulator has no Pencil
        #else
        canvas.drawingPolicy = .pencilOnly  // the Pencil writes, fingers scroll and zoom
        #endif
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
        view.addSubview(canvas)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didCenter, canvas.bounds.width > 0 else { return }
        didCenter = true
        canvas.contentOffset = CGPoint(
            x: (Self.boardSize.width - canvas.bounds.width) / 2, y: (Self.boardSize.height - canvas.bounds.height) / 2)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: canvas)
    }

    // MARK: Stress ink

    /// Adds `count` handwriting-like strokes (one "word" each, 40 points), in a new block of
    /// lines next to the previous block, so twenty adds cover most of the board.
    func addStrokes(_ count: Int) {
        let start = CACurrentMediaTime()
        // Blocks of 800 x 4000 pt, starting where the board opens (its middle) and then
        // alternating right and left; ten more go above.
        let columns: [CGFloat] = [0, 1, -1, 2, -2, 3, -3, 4, -4, 5]
        let block = CGPoint(
            x: 4600 + columns[batches % 10] * 900, y: batches / 10 % 2 == 0 ? 4800 : 300)
        batches += 1
        var generator = SystemRandomNumberGenerator()
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(count)
        let wordsPerLine = 10
        for index in 0..<count {
            let origin = CGPoint(
                x: block.x + CGFloat(index % wordsPerLine) * 80, y: block.y + CGFloat(index / wordsPerLine) * 40)
            strokes.append(Self.word(at: origin, using: &generator))
        }
        canvas.drawing.append(PKDrawing(strokes: strokes))
        state.lastAddMilliseconds = Int((CACurrentMediaTime() - start) * 1000)
        refreshCounts()
    }

    func clear() {
        canvas.drawing = PKDrawing()
        batches = 0
        state.lastAddMilliseconds = nil
        refreshCounts()
    }

    /// Zooms out so all the ink is on screen, to measure the worst case: every stroke visible.
    func zoomToFitInk() {
        let bounds = canvas.drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return }
        canvas.zoom(to: bounds.insetBy(dx: -100, dy: -100), animated: true)
    }

    /// A pen "word": loops along a line, with some wobble, like quick handwriting.
    private static func word(at origin: CGPoint, using generator: inout SystemRandomNumberGenerator) -> PKStroke {
        let length = CGFloat.random(in: 40...65, using: &generator)
        let loops = CGFloat.random(in: 3...6, using: &generator)
        let height = CGFloat.random(in: 8...14, using: &generator)
        let pointCount = 40
        var points: [PKStrokePoint] = []
        points.reserveCapacity(pointCount)
        for step in 0..<pointCount {
            let t = CGFloat(step) / CGFloat(pointCount - 1)
            let angle = t * loops * 2 * .pi
            let location = CGPoint(
                x: origin.x + t * length + cos(angle) * 4,
                y: origin.y - abs(sin(angle)) * height + CGFloat.random(in: -0.8...0.8, using: &generator))
            points.append(PKStrokePoint(
                location: location, timeOffset: TimeInterval(t) * 0.4, size: CGSize(width: 4, height: 4),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: .now)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    // MARK: Counts

    /// Only after "+1000" and "Clear": counting all points after every stroke drawn by hand
    /// would itself cost CPU on a full board and spoil the measurement.
    private func refreshCounts() {
        state.strokeCount = canvas.drawing.strokes.count
        state.pointCount = canvas.drawing.strokes.reduce(0) { $0 + $1.path.count }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        state.zoom = scrollView.zoomScale
    }
}
