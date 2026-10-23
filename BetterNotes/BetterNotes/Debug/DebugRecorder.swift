import Foundation
import UIKit

/// What one window adds to a sample: its canvases and, if a notebook is open, how much of it
/// is in memory. Read from the window itself (see `WindowCounters.read`), so the editor needs
/// no debug hooks.
nonisolated struct WindowCounters: Equatable, Sendable {
    /// Page canvases that exist right now (on screen or about to be).
    var canvases = 0
    /// The highest canvas sharpness multiplier `k` among them (see `EditorCoordinator.renderScale`).
    var renderScale: Double = 0
    /// Page drawings held in memory, and the notebook's page count; nil in the library.
    var loadedDrawings: Int?
    var pages: Int?
}

extension WindowCounters {
    /// Walks the window's views for page overlays. A few hundred views, once per second.
    @MainActor static func read(in window: UIWindow?, notebook: Notebook?) -> WindowCounters {
        var counters = WindowCounters(loadedDrawings: notebook?.loadedPageIDs.count, pages: notebook?.pages.count)
        func visit(_ view: UIView) {
            if let overlay = view as? PageOverlayView {
                counters.canvases += 1
                counters.renderScale = max(counters.renderScale, Double(overlay.renderScale))
                return
            }
            view.subviews.forEach(visit)
        }
        if let window { visit(window) }
        return counters
    }
}

/// One line of a recording.
nonisolated struct DebugRecord: Equatable, Sendable {
    var sample: DebugSample
    var elapsed: TimeInterval
    var counters: WindowCounters

    static let csvHeader =
        "time,elapsed_s,cpu_percent,memory_mb,available_mb,fps,longest_frame_ms,thermal,canvases,render_scale,loaded_drawings,pages"

    /// Numbers use a dot as decimal point whatever the iPad's region, so any spreadsheet or
    /// script reads them. Unknown values (the library has no drawings) stay empty.
    var csvLine: String {
        let fields: [String] = [
            sample.date.formatted(.iso8601),
            String(format: "%.0f", elapsed),
            String(format: "%.1f", sample.cpuPercent),
            String(format: "%.1f", Self.megabytes(sample.memoryFootprint)),
            String(format: "%.0f", Self.megabytes(sample.availableMemory)),
            String(format: "%.1f", sample.framesPerSecond),
            String(format: "%.1f", sample.longestFrameMilliseconds),
            sample.thermalState.debugName,
            String(counters.canvases),
            String(format: "%.0f", counters.renderScale),
            counters.loadedDrawings.map(String.init) ?? "",
            counters.pages.map(String.init) ?? "",
        ]
        return fields.joined(separator: ",")
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
}

extension ProcessInfo.ThermalState {
    nonisolated var debugName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Writes recordings as CSV files, one line per second. They live in Application Support, not
/// in Documents: the library would show a Documents folder as a notebook folder and the backup
/// would include it. The panel shares them through the share sheet instead.
/// This is debug output, not notebook data, so plain appending is fine here (SPEC rule 4 is
/// about notebooks).
nonisolated final class DebugRecorder {
    let url: URL
    let startDate: Date
    private let handle: FileHandle

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Debug", directoryHint: .isDirectory)
    }

    /// Starts a new file named after the moment it starts, like `debug-2026-10-23-1430.csv`.
    init(folder: URL = DebugRecorder.folder, startDate: Date = .now) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.uniqueURL(in: folder, for: startDate)
        try Data((DebugRecord.csvHeader + "\n").utf8).write(to: url)
        self.url = url
        self.startDate = startDate
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func append(_ sample: DebugSample, counters: WindowCounters) {
        let record = DebugRecord(sample: sample, elapsed: sample.date.timeIntervalSince(startDate), counters: counters)
        try? handle.write(contentsOf: Data((record.csvLine + "\n").utf8))
    }

    /// All recordings, newest first.
    static func recordings(in folder: URL = DebugRecorder.folder) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func deleteAll(in folder: URL = DebugRecorder.folder) {
        for url in recordings(in: folder) { try? FileManager.default.removeItem(at: url) }
    }

    private static func uniqueURL(in folder: URL, for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "debug-" + formatter.string(from: date)
        var url = folder.appending(path: base + ".csv")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(number)).csv")
            number += 1
        }
        return url
    }
}
