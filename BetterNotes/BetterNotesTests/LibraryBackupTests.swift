import Foundation
import Testing
@testable import BetterNotes

struct LibraryBackupTests {
    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A small library: a folder with a notebook, a root notebook, a cache and a trashed notebook.
    private func makeLibrary(in folder: TempFolder) throws -> URL {
        let root = folder.url.appending(path: "Documents")
        try put("pdf1", at: root.appending(path: "Uni/Analysis.inkbook/document.pdf"))
        try put("meta1", at: root.appending(path: "Uni/Analysis.inkbook/meta.json"))
        try put("cache", at: root.appending(path: "Uni/Analysis.inkbook/thumbnails/cover.jpg"))
        try put("pdf2", at: root.appending(path: "Notes.inkbook/document.pdf"))
        try put("{}", at: root.appending(path: ".library.json"))
        try put("old", at: root.appending(path: ".Trash/slot/Old.inkbook/document.pdf"))
        return root
    }

    /// File names stored in a ZIP, read from its central directory (no unzip API on iPadOS).
    private func zipEntries(_ zip: URL) throws -> [String] {
        let data = try Data(contentsOf: zip)
        var names: [String] = []
        var i = 0
        while i + 46 <= data.count {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x01, data[i + 3] == 0x02 {
                let nameLength = Int(data[i + 28]) | Int(data[i + 29]) << 8
                let extra = Int(data[i + 30]) | Int(data[i + 31]) << 8
                let comment = Int(data[i + 32]) | Int(data[i + 33]) << 8
                names.append(String(decoding: data[(i + 46)..<(i + 46 + nameLength)], as: UTF8.self))
                i += 46 + nameLength + extra + comment
            } else {
                i += 1
            }
        }
        return names
    }

    @Test func backupHasNotebooksAndFoldersButNoThumbnailsOrTrash() throws {
        let folder = try TempFolder()
        let root = try makeLibrary(in: folder)

        let zip = try LibraryBackup.makeBackup(of: root, date: Date(timeIntervalSince1970: 1_792_000_000))
        defer { LibraryBackup.discard(zip) }

        let names = try zipEntries(zip)
        #expect(zip.lastPathComponent.hasPrefix("Inkbook Backup 20"))
        #expect(names.contains { $0.hasSuffix("Uni/Analysis.inkbook/document.pdf") })
        #expect(names.contains { $0.hasSuffix("Notes.inkbook/document.pdf") })
        #expect(names.contains { $0.hasSuffix(".library.json") })
        #expect(!names.contains { $0.contains("thumbnails") })
        #expect(!names.contains { $0.contains(".Trash") || $0.contains("Old.inkbook") })
    }

    @Test func backupLeavesTheLibraryUntouched() throws {
        let folder = try TempFolder()
        let root = try makeLibrary(in: folder)
        let pdf = root.appending(path: "Notes.inkbook/document.pdf")

        let zip = try LibraryBackup.makeBackup(of: root)
        LibraryBackup.discard(zip)

        #expect(try String(contentsOf: pdf, encoding: .utf8) == "pdf2")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Uni/Analysis.inkbook/thumbnails/cover.jpg").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".Trash/slot/Old.inkbook").path))
    }

    @Test func anEmptyLibraryCannotBeBackedUp() throws {
        let folder = try TempFolder()
        let root = folder.url.appending(path: "Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: BackupError.nothingToBackUp) { try LibraryBackup.makeBackup(of: root) }
        // and no temporary folder is left behind
    }

    @Test func importCopiesAFolderAndNeverOverwrites() throws {
        let folder = try TempFolder()
        let backup = folder.url.appending(path: "Inkbook Backup")
        try put("pdf", at: backup.appending(path: "Uni/A.inkbook/document.pdf"))
        let library = folder.url.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let first = try LibraryBackup.importFolder(from: backup, into: library)
        let second = try LibraryBackup.importFolder(from: backup, into: library)

        #expect(first.url.lastPathComponent == "Inkbook Backup" && first.notebookCount == 1)
        #expect(second.url.lastPathComponent == "Inkbook Backup (2)")
        #expect(FileManager.default.fileExists(atPath: second.url.appending(path: "Uni/A.inkbook/document.pdf").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).filter { $0.hasPrefix(".import") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path) == ["Uni"])  // source untouched
    }

    @Test func importingASingleNotebookKeepsItsName() throws {
        let folder = try TempFolder()
        let source = folder.url.appending(path: "Lecture.inkbook")
        try put("pdf", at: source.appending(path: "document.pdf"))
        let library = folder.url.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let result = try LibraryBackup.importFolder(from: source, into: library)
        let again = try LibraryBackup.importFolder(from: source, into: library)

        #expect(result.url.lastPathComponent == "Lecture.inkbook")
        #expect(again.url.lastPathComponent == "Lecture (2).inkbook")
    }

    @Test func aFolderWithoutNotebooksIsRefusedAndLeavesNothing() throws {
        let folder = try TempFolder()
        let source = folder.url.appending(path: "Photos")
        try put("x", at: source.appending(path: "a.txt"))
        let library = folder.url.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        #expect(throws: BackupError.noNotebooksFound) { try LibraryBackup.importFolder(from: source, into: library) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    @Test func theBackupReminderIsDueAfterFourteenDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var index = LibraryIndex()
        #expect(index.isBackupDue(now: now))  // never backed up
        index.lastBackup = now.addingTimeInterval(-13 * 86400)
        #expect(!index.isBackupDue(now: now))
        index.lastBackup = now.addingTimeInterval(-15 * 86400)
        #expect(index.isBackupDue(now: now))
    }

    @Test func lastBackupSurvivesSavingAndOldFilesStillLoad() throws {
        let folder = try TempFolder()
        let store = LibraryIndexStore(root: folder.url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.update { $0.lastBackup = date }
        #expect(store.load().lastBackup == date)

        try Data(#"{"favorites":[],"sortKey":"name"}"#.utf8).write(to: store.fileURL)
        #expect(store.load().lastBackup == nil)
    }
}
