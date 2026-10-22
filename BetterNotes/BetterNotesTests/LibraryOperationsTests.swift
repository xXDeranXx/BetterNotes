import Foundation
import Testing
@testable import BetterNotes

struct LibraryOperationsTests {
    private struct Fixture {
        let temp: TempFolder
        let location: LibraryLocation
        let registry = OpenNotebookRegistry()
        var operations: LibraryOperations { LibraryOperations(location: location, registry: registry) }
        var root: URL { location.root }

        init() throws {
            temp = try TempFolder()
            location = LibraryLocation(root: temp.url)
            try location.prepare()
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Scanner

    @Test func scannerListsFoldersAndNotebooksAndSkipsHidden() throws {
        let f = try Fixture()
        try f.operations.createFolder(named: "Uni", in: f.root)
        _ = try makeNotebook(in: f.root, title: "Maths")
        try Data().write(to: f.root.appending(path: ".library.json"))

        let contents = LibraryScanner.contents(of: f.root)

        #expect(contents.folders.map(\.name) == ["Uni"])
        #expect(contents.notebooks.map(\.title) == ["Maths"])
        #expect(contents.notebooks[0].pageCount == 1)
    }

    @Test func scannerFindsNestedNotebooksAndFolders() throws {
        let f = try Fixture()
        let uni = try f.operations.createFolder(named: "Uni", in: f.root)
        let analysis = try f.operations.createFolder(named: "Analysis", in: uni)
        _ = try makeNotebook(in: analysis, title: "Lecture 3")

        #expect(LibraryScanner.allNotebooks(under: f.root).map(\.title) == ["Lecture 3"])
        #expect(Set(LibraryScanner.allFolders(under: f.root).map(\.name)) == ["Uni", "Analysis"])
    }

    @Test func damagedNotebookIsListedWithAProblemAndDoesNotHideOthers() throws {
        let f = try Fixture()
        let good = try makeNotebook(in: f.root, title: "Good")
        let bad = try makeNotebook(in: f.root, title: "Bad")
        try Data("not json".utf8).write(to: bad.metaURL)

        let notebooks = LibraryScanner.contents(of: f.root).notebooks

        #expect(notebooks.count == 2)
        #expect(notebooks.first { $0.url == good.url }?.problem == nil)
        let broken = try #require(notebooks.first { $0.url == bad.url })
        #expect(broken.problem != nil)
        #expect(broken.notebookID == nil)
        #expect(broken.title == "Bad")
        #expect(exists(bad.metaURL))  // never repaired by deleting
    }

    @Test func sortingByNameModifiedAndCreated() throws {
        func summary(_ title: String, created: Double, updated: Double) -> NotebookSummary {
            NotebookSummary(
                url: URL(filePath: "/x/\(title).inkbook"), notebookID: UUID(), title: title, coverColor: "#000000",
                createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated),
                pageCount: 1, problem: nil)
        }
        let a = summary("Note 2", created: 3, updated: 1)
        let b = summary("Note 10", created: 1, updated: 2)
        let c = summary("Apple", created: 2, updated: 3)
        let all = [a, b, c]

        #expect(LibraryScanner.sorted(all, by: .name, ascending: true).map(\.title) == ["Apple", "Note 2", "Note 10"])
        #expect(LibraryScanner.sorted(all, by: .name, ascending: false).map(\.title) == ["Note 10", "Note 2", "Apple"])
        #expect(LibraryScanner.sorted(all, by: .modified, ascending: false).map(\.title) == ["Apple", "Note 10", "Note 2"])
        #expect(LibraryScanner.sorted(all, by: .created, ascending: true).map(\.title) == ["Note 10", "Apple", "Note 2"])
    }

    @Test func searchIgnoresCaseAndAccents() throws {
        let f = try Fixture()
        let uni = try f.operations.createFolder(named: "Analysis", in: f.root)
        _ = try makeNotebook(in: uni, title: "Éléments de Géométrie")
        _ = try makeNotebook(in: f.root, title: "Shopping")

        let result = LibraryScanner.search("geometrie", under: f.root)
        #expect(result.notebooks.map(\.title) == ["Éléments de Géométrie"])
        #expect(LibraryScanner.search("ANALY", under: f.root).folders.map(\.name) == ["Analysis"])
        #expect(LibraryScanner.search("  ", under: f.root).notebooks.isEmpty)
    }

    // MARK: Folders, rename

    @Test func createFolderAvoidsNameClash() throws {
        let f = try Fixture()
        let first = try f.operations.createFolder(named: "Uni", in: f.root)
        let second = try f.operations.createFolder(named: "Uni", in: f.root)
        #expect(first.lastPathComponent == "Uni")
        #expect(second.lastPathComponent == "Uni 2")
    }

    @Test func renameNotebookChangesTitleAndFileName() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Old")

        let renamed = try f.operations.rename(package.url, to: "New Name")

        #expect(renamed.lastPathComponent == "New Name.inkbook")
        #expect(!exists(package.url))
        #expect(try NotebookPackage(url: renamed).readMeta().title == "New Name")
    }

    @Test func renameFolderKeepsContent() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "Sem 1", in: f.root)
        _ = try makeNotebook(in: folder, title: "Inside")

        let renamed = try f.operations.rename(folder, to: "Semester 1")

        #expect(LibraryScanner.contents(of: renamed).notebooks.map(\.title) == ["Inside"])
    }

    @Test func renameToTakenNameNeverOverwrites() throws {
        let f = try Fixture()
        let a = try makeNotebook(in: f.root, title: "A")
        let b = try makeNotebook(in: f.root, title: "B")

        let renamed = try f.operations.rename(b.url, to: "A")

        #expect(renamed.lastPathComponent == "A 2.inkbook")
        #expect(exists(a.url))
    }

    @Test func renameWithSlashesProducesSafeFileName() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "X")
        let renamed = try f.operations.rename(package.url, to: "Math/Physics")
        #expect(renamed.deletingLastPathComponent().standardizedFileURL == f.root.standardizedFileURL)
        #expect(try NotebookPackage(url: renamed).readMeta().title == "Math/Physics")
    }

    // MARK: Move

    @Test func moveNotebookIntoFolderKeepsInkAndIdentity() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Lecture")
        let meta = try package.readMeta()
        try package.saveDrawing(sampleDrawing(), for: meta.pages[0].id)
        let folder = try f.operations.createFolder(named: "Uni", in: f.root)

        let moved = try f.operations.move(package.url, into: folder)

        #expect(!exists(package.url))
        let movedPackage = NotebookPackage(url: moved)
        #expect(try movedPackage.readMeta().id == meta.id)
        #expect(try movedPackage.loadDrawing(for: meta.pages[0].id) != nil)
    }

    @Test func moveIntoFolderWithSameNameKeepsBoth() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "Uni", in: f.root)
        let existing = try makeNotebook(in: folder, title: "Notes")
        let incoming = try makeNotebook(in: f.root, title: "Notes")

        let moved = try f.operations.move(incoming.url, into: folder)

        #expect(moved.lastPathComponent == "Notes 2.inkbook")
        #expect(exists(existing.url))
    }

    @Test func folderCannotMoveIntoItselfOrItsChildren() throws {
        let f = try Fixture()
        let parent = try f.operations.createFolder(named: "A", in: f.root)
        let child = try f.operations.createFolder(named: "B", in: parent)

        #expect(throws: LibraryError.moveIntoItself) { try f.operations.move(parent, into: parent) }
        #expect(throws: LibraryError.moveIntoItself) { try f.operations.move(parent, into: child) }
        #expect(exists(child))
    }

    @Test func movingFolderToSimilarlyNamedSiblingIsAllowed() throws {
        // "A" must not be mistaken for the parent of "AB" by a plain prefix comparison.
        let f = try Fixture()
        let a = try f.operations.createFolder(named: "A", in: f.root)
        let ab = try f.operations.createFolder(named: "AB", in: f.root)
        let moved = try f.operations.move(a, into: ab)
        #expect(exists(moved))
    }

    @Test func moveIntoNotebookIsRefused() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "F", in: f.root)
        let notebook = try makeNotebook(in: f.root, title: "N")
        #expect(throws: LibraryError.notAFolder) { try f.operations.move(folder, into: notebook.url) }
    }

    @Test func moveToSameFolderDoesNothing() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "N")
        #expect(try f.operations.move(package.url, into: f.root) == package.url)
        #expect(exists(package.url))
    }

    // MARK: Open notebooks are protected

    @Test func openNotebookCannotBeMovedRenamedOrTrashed() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Open")
        let folder = try f.operations.createFolder(named: "F", in: f.root)
        #expect(f.registry.claim(package.url))

        #expect(throws: LibraryError.isOpen) { try f.operations.move(package.url, into: folder) }
        #expect(throws: LibraryError.isOpen) { try f.operations.rename(package.url, to: "Other") }
        #expect(throws: LibraryError.isOpen) { try f.operations.trash(package.url) }
        #expect(exists(package.url))
        #expect(try package.readMeta().title == "Open")
    }

    @Test func folderContainingAnOpenNotebookCannotBeTrashed() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "F", in: f.root)
        let package = try makeNotebook(in: folder, title: "Open")
        #expect(f.registry.claim(package.url))

        #expect(throws: LibraryError.isOpen) { try f.operations.trash(folder) }
        #expect(exists(package.url))
    }

    // MARK: Duplicate

    @Test func duplicateCopiesInkWithNewIdentity() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Original")
        let meta = try package.readMeta()
        try package.saveDrawing(sampleDrawing(), for: meta.pages[0].id)

        let copy = try f.operations.duplicate(package.url)

        let copyPackage = NotebookPackage(url: copy)
        let copyMeta = try copyPackage.readMeta()
        #expect(copy.lastPathComponent == "Original copy.inkbook")
        #expect(copyMeta.title == "Original copy")
        #expect(copyMeta.id != meta.id)
        #expect(copyMeta.pages.map(\.id) == meta.pages.map(\.id))
        #expect(try copyPackage.loadDrawing(for: meta.pages[0].id) != nil)
        #expect(try package.readMeta() == meta)  // the original is untouched
        #expect(LibraryScanner.contents(of: f.root).notebooks.count == 2)
    }

    @Test func duplicateLeavesNoStagingFolder() throws {
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Original")
        _ = try f.operations.duplicate(package.url)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    // MARK: Trash

    @Test func trashMovesItemAndPutBackRestoresIt() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "Uni", in: f.root)
        let package = try makeNotebook(in: folder, title: "Lecture")

        let trashed = try f.operations.trash(package.url)

        #expect(!exists(package.url))
        #expect(exists(trashed.url))
        #expect(f.operations.trashedItems().map(\.name) == ["Lecture.inkbook"])
        #expect(f.operations.trashedItems()[0].originalParent == "Uni")

        let restored = try f.operations.putBack(f.operations.trashedItems()[0])
        #expect(restored.standardizedFileURL == package.url.standardizedFileURL)
        #expect(f.operations.trashedItems().isEmpty)
        #expect(try NotebookPackage(url: restored).readMeta().title == "Lecture")
    }

    @Test func putBackGoesToRootWhenFolderIsGone() throws {
        let f = try Fixture()
        let folder = try f.operations.createFolder(named: "Uni", in: f.root)
        let package = try makeNotebook(in: folder, title: "Lecture")
        let trashed = try f.operations.trash(package.url)
        _ = try f.operations.trash(folder)  // the folder is now in the trash too

        let restored = try f.operations.putBack(trashed)

        #expect(restored.deletingLastPathComponent().standardizedFileURL == f.root.standardizedFileURL)
    }

    @Test func trashingTwoItemsWithTheSameNameKeepsBoth() throws {
        let f = try Fixture()
        let first = try makeNotebook(in: f.root, title: "Same")
        try f.operations.trash(first.url)
        let second = try makeNotebook(in: f.root, title: "Same")
        try f.operations.trash(second.url)
        #expect(f.operations.trashedItems().count == 2)
    }

    @Test func purgeRemovesOnlyItemsOlderThan30Days() throws {
        let f = try Fixture()
        let old = try makeNotebook(in: f.root, title: "Old")
        let recent = try makeNotebook(in: f.root, title: "Recent")
        let now = Date()
        try f.operations.trash(old.url, now: now.addingTimeInterval(-31 * 24 * 3600))
        try f.operations.trash(recent.url, now: now.addingTimeInterval(-29 * 24 * 3600))

        #expect(f.operations.purgeExpired(now: now) == 1)

        #expect(f.operations.trashedItems().map(\.name) == ["Recent.inkbook"])
    }

    @Test func emptyTrashRemovesEverythingInTrashAndNothingElse() throws {
        let f = try Fixture()
        let keep = try makeNotebook(in: f.root, title: "Keep")
        let gone = try makeNotebook(in: f.root, title: "Gone")
        try f.operations.trash(gone.url)

        #expect(f.operations.emptyTrash() == 1)

        #expect(f.operations.trashedItems().isEmpty)
        #expect(exists(keep.url))
    }

    @Test func nothingOutsideTheLibraryOrInTheTrashCanBeChanged() throws {
        let f = try Fixture()
        let outside = try TempFolder()
        let stranger = outside.url.appending(path: "X.inkbook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let trashed = try f.operations.trash(try makeNotebook(in: f.root, title: "T").url)

        #expect(throws: LibraryError.outsideLibrary) { try f.operations.trash(stranger) }
        #expect(throws: LibraryError.outsideLibrary) { try f.operations.rename(stranger, to: "Y") }
        #expect(throws: LibraryError.outsideLibrary) { try f.operations.rename(trashed.url, to: "Y") }
        #expect(exists(stranger))
        #expect(!f.operations.purge(TrashedItem(
            id: UUID(), url: stranger, name: "X.inkbook", trashedAt: .now, originalParent: "")))
        #expect(exists(stranger))
    }

    // MARK: .library.json

    @Test func indexRoundTripsAndFavoritesAreToggled() throws {
        let f = try Fixture()
        let store = LibraryIndexStore(root: f.root)
        let id = UUID()

        try store.update { $0.toggleFavorite(id); $0.sortKey = .modified; $0.sortAscending = false }

        let loaded = store.load()
        #expect(loaded.isFavorite(id))
        #expect(loaded.sortKey == .modified)
        #expect(!loaded.sortAscending)
        try store.update { $0.toggleFavorite(id) }
        #expect(!store.load().isFavorite(id))
    }

    @Test func recentsAreNewestFirstWithoutDuplicatesAndCapped() {
        var index = LibraryIndex()
        let ids = (0..<12).map { _ in UUID() }
        ids.forEach { index.recordOpened($0) }
        index.recordOpened(ids[5])

        #expect(index.recents.count == LibraryIndex.maxRecents)
        #expect(index.recents.first == ids[5])
        #expect(Set(index.recents).count == index.recents.count)
    }

    @Test func missingOrBrokenIndexGivesDefaultsAndKeepsTheBrokenFile() throws {
        let f = try Fixture()
        let store = LibraryIndexStore(root: f.root)
        #expect(store.load() == LibraryIndex())

        try Data("{ broken".utf8).write(to: store.fileURL)
        #expect(store.load() == LibraryIndex())
        #expect(exists(f.root.appending(path: ".library.json.unreadable")))
    }

    @Test func indexWithUnknownOrMissingFieldsStillLoads() throws {
        let f = try Fixture()
        let id = UUID()
        let json = #"{"favorites": ["\#(id.uuidString)"], "sortKey": "weird", "future": 1}"#
        try Data(json.utf8).write(to: LibraryIndexStore(root: f.root).fileURL)

        let loaded = LibraryIndexStore(root: f.root).load()
        #expect(loaded.favorites == [id])
        #expect(loaded.sortKey == .name)
    }

    @Test func notebookMovedBehindTheAppsBackIsStillFoundByIdentity() throws {
        // What the Files app does: it moves the folder. Favorites are by id, so they follow.
        let f = try Fixture()
        let package = try makeNotebook(in: f.root, title: "Lecture")
        let id = try package.readMeta().id
        try LibraryIndexStore(root: f.root).update { $0.toggleFavorite(id) }
        let folder = f.root.appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: package.url, to: folder.appending(path: "Lecture.inkbook"))

        let favorites = LibraryIndexStore(root: f.root).load().favorites
        let found = LibraryScanner.allNotebooks(under: f.root).filter { favorites.contains($0.notebookID ?? UUID()) }

        #expect(found.map(\.title) == ["Lecture"])
    }
}
