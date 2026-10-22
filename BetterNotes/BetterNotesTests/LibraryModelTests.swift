import Foundation
import Testing
@testable import BetterNotes

@MainActor
struct LibraryModelTests {
    private func makeModel() throws -> (LibraryModel, TempFolder) {
        let temp = try TempFolder()
        return (LibraryModel(location: LibraryLocation(root: temp.url), registry: OpenNotebookRegistry()), temp)
    }

    @Test func dragPayloadRoundTripsToTheSameItem() throws {
        let (model, temp) = try makeModel()
        let item = temp.url.appending(path: "Uni/Lecture.inkbook")
        let payload = model.dragPayload(for: item)
        #expect(payload.hasPrefix("inkbook-item:"))
        #expect(model.dragged(from: payload)?.standardizedFileURL.path == item.standardizedFileURL.path)
    }

    @Test func foreignOrEscapingDropPayloadsAreIgnored() throws {
        let (model, _) = try makeModel()
        #expect(model.dragged(from: "some random text") == nil)
        #expect(model.dragged(from: "inkbook-item:../../etc") == nil)
        #expect(model.dragged(from: "inkbook-item:/etc") == nil)
        #expect(model.dragged(from: "inkbook-item:") == nil)
        #expect(model.dragged(from: "inkbook-item:Notes..x.inkbook") != nil)
    }

    @Test func breadcrumbsRunFromRootToCurrentFolder() async throws {
        let (model, temp) = try makeModel()
        let nested = temp.url.appending(path: "Uni/Analysis", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        await model.show(folder: nested)
        #expect(model.breadcrumbs.map(\.lastPathComponent).suffix(2) == ["Uni", "Analysis"])
        #expect(model.breadcrumbs.count == 3)
    }

    @Test func foldersThatDisappearSendTheUserBackToTheRoot() async throws {
        let (model, temp) = try makeModel()
        let nested = temp.url.appending(path: "Gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        await model.show(folder: nested)
        try FileManager.default.removeItem(at: nested)  // moved away in the Files app
        await model.reload()
        #expect(model.isAtRoot)
    }

    @Test func favoritesFollowANotebookIntoAnotherFolderOnRescan() async throws {
        let (model, temp) = try makeModel()
        let package = try makeNotebook(in: temp.url, title: "Lecture")
        await model.reload()
        await model.select(.favorites)
        await model.toggleFavorite(try #require(model.contents.notebooks.first))
        let folder = temp.url.appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: package.url, to: folder.appending(path: "Lecture.inkbook"))
        await model.reload()
        #expect(model.shownNotebooks.map(\.title) == ["Lecture"])
    }

    // MARK: Selection, bulk actions, layout

    @Test func selectionTogglesSelectsAllAndEndsWhenLeavingAFolder() async throws {
        let (model, temp) = try makeModel()
        _ = try makeNotebook(in: temp.url, title: "A")
        _ = try makeNotebook(in: temp.url, title: "B")
        await model.reload()

        model.startSelecting()
        #expect(model.isSelecting && model.selection.isEmpty)
        model.toggleSelection(model.selectableURLs[0])
        #expect(model.selection.count == 1 && !model.allSelected)
        model.selectAll()
        #expect(model.allSelected)
        model.toggleSelection(model.selectableURLs[0])
        #expect(model.selection.count == 1)

        await model.select(.favorites)
        #expect(!model.isSelecting && model.selection.isEmpty)
    }

    @Test func movingASelectionMovesEveryItemAndEndsSelecting() async throws {
        let (model, temp) = try makeModel()
        let a = try makeNotebook(in: temp.url, title: "A")
        let b = try makeNotebook(in: temp.url, title: "B")
        let folder = try model.operations.createFolder(named: "Uni", in: temp.url)
        await model.reload()

        model.startSelecting()
        model.toggleSelection(a.url)
        model.toggleSelection(b.url)
        await model.moveSelection(into: folder)

        #expect(!model.isSelecting)
        #expect(LibraryScanner.contents(of: folder).notebooks.map(\.title).sorted() == ["A", "B"])
        #expect(model.contents.notebooks.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func trashingASelectionSkipsAnOpenNotebookAndSaysSo() async throws {
        let temp = try TempFolder()
        let registry = OpenNotebookRegistry()
        let model = LibraryModel(location: LibraryLocation(root: temp.url), registry: registry)
        let open = try makeNotebook(in: temp.url, title: "Open")
        let other = try makeNotebook(in: temp.url, title: "Other")
        #expect(registry.claim(open.url))
        await model.reload()

        model.startSelecting()
        model.selectAll()
        await model.trashSelection()

        #expect(FileManager.default.fileExists(atPath: open.url.path))  // protected, still there
        #expect(!FileManager.default.fileExists(atPath: other.url.path))  // the rest went through
        #expect(model.errorMessage?.contains("Open") == true)
        #expect(model.operations.trashedItems().count == 1)
    }

    @Test func layoutChoiceIsRememberedAcrossModels() async throws {
        let temp = try TempFolder()
        let location = LibraryLocation(root: temp.url)
        let first = LibraryModel(location: location, registry: OpenNotebookRegistry())
        first.setLayout(.list)

        let second = LibraryModel(location: location, registry: OpenNotebookRegistry())
        await second.reload()
        #expect(second.index.layout == .list)
    }
}
