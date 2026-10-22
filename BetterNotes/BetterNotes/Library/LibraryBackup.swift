import Foundation

nonisolated enum BackupError: LocalizedError, Equatable {
    case nothingToBackUp
    case zipFailed
    case noNotebooksFound

    var errorDescription: String? {
        switch self {
        case .nothingToBackUp: "The library is empty, so there is nothing to back up."
        case .zipFailed: "The backup file could not be created. Check that the iPad has enough free space."
        case .noNotebooksFound: "This folder contains no notebooks (no .inkbook files), so nothing was imported."
        }
    }
}

/// Library backup as one ZIP file, and "Import folder" to bring a backup (or any folder of
/// notebooks) back. No ZIP library is needed: asking `NSFileCoordinator` to read a folder
/// `.forUploading` makes iPadOS zip it, the same way the Files app's "Compress" does.
nonisolated enum LibraryBackup {
    /// Makes `<temporary folder>/Inkbook Backup <date>.zip` of everything in `root` except
    /// the trash and the thumbnail caches, and returns it. The caller shares or moves the file
    /// and removes its folder afterwards (`discard`).
    ///
    /// The ZIP has to be made from a folder that contains exactly the right files, so the
    /// files are first **hard-linked** into a staging folder. A hard link is a second name for
    /// the same file on disk: it costs no space (the iPad may be nearly full) and takes no
    /// time. If linking is impossible the file is copied instead. Every write in the app
    /// replaces a file instead of changing it in place, so a link never sees a half-written file.
    static func makeBackup(of root: URL, name: String? = nil, date: Date = .now) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "Backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folderName = (name ?? "Inkbook Backup") + " " + date.formatted(.iso8601.year().month().day())
        let staging = work.appending(path: folderName, directoryHint: .isDirectory)
        let zipURL = work.appending(path: folderName + ".zip")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            guard try stage(root, into: staging, isTop: true) > 0 else { throw BackupError.nothingToBackUp }

            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) {
                temporaryZip in
                // The system deletes its zip when this block ends, so take it out right here.
                // Moving costs no space; copying (the fallback) would need the ZIP's size twice.
                do {
                    do { try FileManager.default.moveItem(at: temporaryZip, to: zipURL) }
                    catch { try FileManager.default.copyItem(at: temporaryZip, to: zipURL) }
                } catch { copyError = error }
            }
            if coordinationError != nil || copyError != nil { throw BackupError.zipFailed }
            try? FileManager.default.removeItem(at: staging)  // only links: the notebooks are untouched
            return zipURL
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Removes a backup file and its temporary folder.
    static func discard(_ zipURL: URL) {
        try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent())
    }

    /// Mirrors `source` into `destination` (folders created, files linked or copied), leaving
    /// out `.Trash` at the top and every `thumbnails` folder. Returns the number of files.
    private static func stage(_ source: URL, into destination: URL, isTop: Bool = false) throws -> Int {
        let manager = FileManager.default
        var count = 0
        for item in try manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            let name = item.lastPathComponent
            if name == "thumbnails" || (isTop && name == ".Trash") { continue }
            let target = destination.appending(path: name)
            if (try item.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
                count += try stage(item, into: target)
            } else {
                do { try manager.linkItem(at: item, to: target) } catch { try manager.copyItem(at: item, to: target) }
                count += 1
            }
        }
        return count
    }

    // MARK: Import folder

    /// Copies the folder `source` (an unzipped backup, or any folder with notebooks) into
    /// `parent` as a new folder with the same name; a name that is taken gets a number in
    /// brackets, so nothing is ever overwritten or merged. A `.inkbook` picked directly is
    /// copied as one notebook. Returns the new item and the number of notebooks in it.
    /// The caller has security-scoped access to `source` while this runs.
    ///
    /// The copy happens in a hidden staging folder and is renamed into place at the end, so an
    /// interruption leaves no half-imported folder in the library.
    @discardableResult
    static func importFolder(from source: URL, into parent: URL) throws -> (url: URL, notebookCount: Int) {
        let isNotebook = source.pathExtension == NotebookPackage.fileExtension
        let notebookCount = isNotebook ? 1 : countNotebooks(in: source)
        guard notebookCount > 0 else { throw BackupError.noNotebooksFound }

        let manager = FileManager.default
        let staging = parent.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let staged = staging.appending(path: source.lastPathComponent)
        try manager.copyItem(at: source, to: staged)
        let target = LibraryOperations.uniqueURL(
            in: parent, baseName: isNotebook ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent,
            pathExtension: isNotebook ? NotebookPackage.fileExtension : nil)
        try manager.moveItem(at: staged, to: target)
        return (target, notebookCount)
    }

    private static func countNotebooks(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let item as URL in walker where item.pathExtension == NotebookPackage.fileExtension {
            count += 1
            walker.skipDescendants()  // what is inside a notebook is not another notebook
        }
        return count
    }
}
