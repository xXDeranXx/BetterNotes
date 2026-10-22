import Foundation
import Testing
@testable import BetterNotes

struct StorageSizeTests {
    private func write(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: count).write(to: url)
    }

    @Test func countsFilesButNotThumbnailsOrTheTopLevelTrash() throws {
        let folder = try TempFolder()
        let root = folder.url
        try write(1000, to: root.appending(path: "A.inkbook/document.pdf"))
        try write(200, to: root.appending(path: "A.inkbook/drawings/x.drawing"))
        try write(50_000, to: root.appending(path: "A.inkbook/thumbnails/cover.jpg"))
        try write(300, to: root.appending(path: "Sub/.folder.json"))
        try write(70_000, to: root.appending(path: ".Trash/slot/B.inkbook/document.pdf"))

        #expect(StorageSize.bytes(of: root) == 1500)
        #expect(StorageSize.bytes(of: root.appending(path: "A.inkbook")) == 1200)
    }

    @Test func formatsForPeople() {
        #expect(StorageSize.format(0) == "Zero KB")
        #expect(StorageSize.format(4_200_000).contains("MB"))
    }
}
