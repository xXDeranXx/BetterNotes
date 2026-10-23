import Foundation
import Testing
import UIKit
@testable import BetterNotes

/// The debug overlay is temporary; delete this file together with the Debug folder.
struct DebugOverlayTests {
    private func sample(at date: Date = Date(timeIntervalSince1970: 1_000)) -> DebugSample {
        DebugSample(
            date: date, cpuPercent: 37.26, memoryFootprint: 300 * 1_048_576, availableMemory: 2048 * 1_048_576,
            framesPerSecond: 119.6, longestFrameMilliseconds: 16.71, thermalState: .serious)
    }

    @Test func csvLineHasOneFieldPerHeaderColumn() {
        let record = DebugRecord(
            sample: sample(), elapsed: 42.4,
            counters: WindowCounters(canvases: 3, renderScale: 4, loadedDrawings: 5, pages: 120))
        let fields = record.csvLine.split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields.count == DebugRecord.csvHeader.split(separator: ",").count)
        #expect(Array(fields.dropFirst()) == ["42", "37.3", "300.0", "2048", "119.6", "16.7", "serious", "3", "4", "5", "120"])
    }

    @Test func libraryLeavesNotebookFieldsEmpty() {
        let record = DebugRecord(sample: sample(), elapsed: 0, counters: WindowCounters())
        #expect(record.csvLine.hasSuffix(",0,0,,"))
    }

    @Test func dragFlipsCornerOnlyPastThreshold() {
        #expect(Corner.bottomTrailing.moved(by: CGSize(width: -50, height: -50)) == .bottomTrailing)
        #expect(Corner.bottomTrailing.moved(by: CGSize(width: -300, height: 0)) == .bottomLeading)
        #expect(Corner.bottomTrailing.moved(by: CGSize(width: -300, height: -500)) == .topLeading)
        #expect(Corner.topLeading.moved(by: CGSize(width: 300, height: 10)) == .topTrailing)
    }

    @Test func recorderWritesHeaderAndLines() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_000)
        var recorder: DebugRecorder? = try DebugRecorder(folder: folder, startDate: start)
        let url = try #require(recorder?.url)
        recorder?.append(sample(at: start.addingTimeInterval(1)), counters: WindowCounters())
        recorder?.append(sample(at: start.addingTimeInterval(2)), counters: WindowCounters())
        recorder = nil  // closes the file

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == Substring(DebugRecord.csvHeader))
        #expect(lines[2].split(separator: ",")[1] == "2")

        // A second recording in the same second gets its own file.
        let second = try DebugRecorder(folder: folder, startDate: start)
        #expect(second.url != url)
        #expect(DebugRecorder.recordings(in: folder).count == 2)
        DebugRecorder.deleteAll(in: folder)
        #expect(DebugRecorder.recordings(in: folder).isEmpty)
    }

    @Test func processMetricsReturnPlausibleValues() {
        #expect(ProcessMetrics.memoryFootprint() > 1_048_576)
        let cpu = ProcessMetrics.cpuPercent()
        #expect(cpu >= 0 && cpu < 10_000)
    }

    @Test @MainActor func countersFindPageOverlaysInTheWindow() {
        let root = UIView()
        let container = UIView()
        root.addSubview(container)
        let first = PageOverlayView(pageID: UUID())
        first.renderScale = 2
        let second = PageOverlayView(pageID: UUID())
        second.renderScale = 5
        container.addSubview(first)
        root.addSubview(second)
        let window = UIWindow(frame: .zero)
        window.addSubview(root)

        let counters = WindowCounters.read(in: window, notebook: nil)
        #expect(counters.canvases == 2)
        #expect(counters.renderScale == 5)
        #expect(counters.loadedDrawings == nil)
    }
}
