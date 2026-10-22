import Foundation
import Testing
@testable import BetterNotes

struct LibraryLocationTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func prepareCreatesTrashFolder() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try LibraryLocation(root: root).prepare()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: root.appending(path: ".Trash").path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
    }

    @Test func prepareKeepsExistingFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = LibraryLocation(root: root)
        try location.prepare()
        let note = location.trash.appending(path: "old.txt")
        try Data("keep me".utf8).write(to: note)

        try location.prepare()

        #expect(try Data(contentsOf: note) == Data("keep me".utf8))
    }
}
