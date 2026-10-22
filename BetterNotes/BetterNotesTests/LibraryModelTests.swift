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
}
