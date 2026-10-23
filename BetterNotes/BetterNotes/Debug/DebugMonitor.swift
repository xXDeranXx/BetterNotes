import Foundation
import Observation
import QuartzCore

/// One reading per second of what the whole app costs. CPU and memory belong to the process,
/// not to a window, so there is one monitor for the app; each window's panel adds its own
/// counters (see `WindowCounters`).
nonisolated struct DebugSample: Equatable, Sendable {
    var date: Date
    var cpuPercent: Double
    var memoryFootprint: UInt64
    var availableMemory: UInt64
    /// Frames the main thread finished in the last second.
    var framesPerSecond: Double
    /// The longest gap between two frames in the last second, in milliseconds (a hitch).
    var longestFrameMilliseconds: Double
    var thermalState: ProcessInfo.ThermalState
}

/// Samples CPU, memory, frame rate and the thermal state once per second while at least one
/// panel is on screen, and does nothing otherwise. `CADisplayLink` calls us once per screen
/// refresh (like `requestAnimationFrame` in a browser), which is how frames are counted.
/// Note: a running display link may keep a ProMotion screen at its highest refresh rate, so
/// the panel itself costs a little energy; compare measurements with the panel always on.
@Observable
final class DebugMonitor {
    static let shared = DebugMonitor()

    private(set) var sample: DebugSample?

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var frameCounter: FrameCounter?

    /// Each panel calls `start` when it appears and `stop` when it goes away.
    func start() {
        users += 1
        guard users == 1 else { return }
        let counter = FrameCounter()
        counter.start()
        frameCounter = counter
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeSample() }
        }
        takeSample()
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        frameCounter?.stop()
        frameCounter = nil
        sample = nil
    }

    private func takeSample() {
        let frames = frameCounter?.takeStatistics() ?? (fps: 0, longest: 0)
        sample = DebugSample(
            date: .now,
            cpuPercent: ProcessMetrics.cpuPercent(),
            memoryFootprint: ProcessMetrics.memoryFootprint(),
            availableMemory: ProcessMetrics.availableMemory(),
            framesPerSecond: frames.fps,
            longestFrameMilliseconds: frames.longest * 1000,
            thermalState: ProcessInfo.processInfo.thermalState)
    }
}

/// Counts screen refreshes. `CADisplayLink` needs an Objective-C target object, so this small
/// class exists only to receive its calls.
private final class FrameCounter: NSObject {
    private var link: CADisplayLink?
    private var frames = 0
    private var lastTimestamp: CFTimeInterval?
    private var longestGap: CFTimeInterval = 0
    private var periodStart = CACurrentMediaTime()

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)  // also while scrolling
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        frames += 1
        if let lastTimestamp { longestGap = max(longestGap, link.timestamp - lastTimestamp) }
        lastTimestamp = link.timestamp
    }

    /// Frames per second and the longest gap (seconds) since the last call, then starts over.
    func takeStatistics() -> (fps: Double, longest: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let elapsed = max(now - periodStart, 0.001)
        let result = (fps: Double(frames) / elapsed, longest: longestGap)
        frames = 0
        longestGap = 0
        periodStart = now
        return result
    }
}
