import Foundation
import PDFKit
import PencilKit
import Testing
@testable import BetterNotes

@MainActor
struct PageTransferTests {
    private struct Setup {
        let folder: TempFolder
        let source: Notebook
        let targetPackage: NotebookPackage
    }

    /// A source notebook "S1".."S4" and a target notebook "T1", "T2" in one library folder.
    private func makeSetup() throws -> Setup {
        let folder = try TempFolder()
        let library = folder.url.appending(path: "library")
        let sourcePDF = try makeLabeledPDF(in: folder.url, name: "s.pdf", labels: ["S1", "S2", "S3", "S4"])
        let targetPDF = try makeLabeledPDF(in: folder.url, name: "t.pdf", labels: ["T1", "T2"])
        let sourcePackage = try NotebookPackage.importPDF(from: sourcePDF, in: library, title: "Source", coverColor: "#000000")
        let targetPackage = try NotebookPackage.importPDF(from: targetPDF, in: library, title: "Target", coverColor: "#000000")
        let source = try Notebook.open(sourcePackage)
        source.autosaveDelay = .seconds(60)
        return Setup(folder: folder, source: source, targetPackage: targetPackage)
    }

    private func labels(_ notebook: Notebook) -> [String] {
        let document = notebook.document!
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func copyingAddsThePagesWithTheirInkToTheEndOfTheTargetAndKeepsTheSource() async throws {
        let setup = try makeSetup()
        let page = setup.source.pages[1].id
        setup.source.setDrawing(sampleDrawing(), for: page)  // unsaved ink travels too

        try await PageTransfer.transfer([page, setup.source.pages[3].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: false)

        #expect(labels(setup.source) == ["S1", "S2", "S3", "S4"])  // source unchanged
        let target = try Notebook.open(setup.targetPackage)  // read back from disk
        #expect(labels(target) == ["T1", "T2", "S2", "S4"])
        #expect(target.document?.pageCount == target.pages.count)
        #expect(target.drawing(for: target.pages[2].id).strokes.count == 1)  // the ink came along
        #expect(target.pages[2].id != page)  // a new page, not the same id
        #expect(target.drawing(for: target.pages[3].id).strokes.isEmpty)
    }

    @Test func movingRemovesThePagesFromTheSourceAfterTheTargetHasThem() async throws {
        let setup = try makeSetup()
        let moved = setup.source.pages[0].id
        setup.source.setDrawing(sampleDrawing(), for: moved)

        try await PageTransfer.transfer([moved], from: setup.source, toNotebookAt: setup.targetPackage.url, move: true)

        #expect(labels(setup.source) == ["S2", "S3", "S4"])
        let target = try Notebook.open(setup.targetPackage)
        #expect(labels(target) == ["T1", "T2", "S1"])
        #expect(target.drawing(for: target.pages[2].id).strokes.count == 1)
    }

    @Test func undoingAMoveBringsThePagesBackInTheSourceAndLeavesTheCopies() async throws {
        let setup = try makeSetup()
        try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: true)

        setup.source.undoManager.undo()

        #expect(labels(setup.source) == ["S1", "S2", "S3", "S4"])
        #expect(labels(try Notebook.open(setup.targetPackage)) == ["T1", "T2", "S1"])  // nothing is lost
    }

    @Test func movingEveryPageIsRefusedBeforeAnythingChanges() async throws {
        let setup = try makeSetup()

        await #expect(throws: NotebookError.cannotDeleteAllPages) {
            try await PageTransfer.transfer(Set(setup.source.pages.map(\.id)), from: setup.source, toNotebookAt: setup.targetPackage.url, move: true)
        }

        #expect(labels(try Notebook.open(setup.targetPackage)) == ["T1", "T2"])
        #expect(labels(setup.source).count == 4)
    }

    @Test func copyingEveryPageIsAllowed() async throws {
        let setup = try makeSetup()

        try await PageTransfer.transfer(Set(setup.source.pages.map(\.id)), from: setup.source, toNotebookAt: setup.targetPackage.url, move: false)

        #expect(labels(try Notebook.open(setup.targetPackage)) == ["T1", "T2", "S1", "S2", "S3", "S4"])
    }

    @Test func aTargetThatIsOpenInAnotherWindowIsRefusedAndUntouched() async throws {
        let setup = try makeSetup()
        let registry = OpenNotebookRegistry()
        #expect(registry.claim(setup.targetPackage.url))  // "another window" has it open

        await #expect(throws: NotebookError.alreadyOpen) {
            try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: true, registry: registry)
        }

        #expect(labels(try Notebook.open(setup.targetPackage)) == ["T1", "T2"])
        #expect(labels(setup.source).count == 4)
    }

    @Test func theTargetIsLetGoOfAfterwards() async throws {
        let setup = try makeSetup()
        let registry = OpenNotebookRegistry()

        try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: false, registry: registry)

        #expect(registry.claim(setup.targetPackage.url))  // free again, so it can be opened in a window
    }

    @Test func aTargetThatCannotBeSavedMeansNothingIsMoved() async throws {
        let setup = try makeSetup()
        let folder = setup.targetPackage.url
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await #expect(throws: PageTransfer.TransferError.self) {
            try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: true)
        }

        #expect(labels(setup.source) == ["S1", "S2", "S3", "S4"])  // the pages are still here
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(labels(try Notebook.open(setup.targetPackage)) == ["T1", "T2"])
    }

    @Test func transferringIntoTheSameNotebookIsRefused() async throws {
        let setup = try makeSetup()

        await #expect(throws: NotebookError.sameNotebook) {
            try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.source.package.url, move: false)
        }
    }

    @Test func aTargetWhoseListAndPDFDisagreeIsRefused() async throws {
        let setup = try makeSetup()
        var meta = try setup.targetPackage.readMeta()
        meta.pages.append(PageMeta(template: .lined, size: .a4Portrait))
        try setup.targetPackage.writeMeta(meta)

        await #expect(throws: NotebookError.pagesCannotBeChanged) {
            try await PageTransfer.transfer([setup.source.pages[0].id], from: setup.source, toNotebookAt: setup.targetPackage.url, move: false)
        }
    }
}
