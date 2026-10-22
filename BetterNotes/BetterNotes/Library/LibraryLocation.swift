import Foundation

/// The folder that holds the whole library. Everything the app stores lives
/// below `root`, which is the app's Documents folder, so it shows up in the
/// Files app (see `UIFileSharingEnabled` in Info.plist).
///
/// `nonisolated` opts out of the project-wide "everything runs on the main
/// thread" default, so file work can later run in the background and tests
/// can call it without `await`.
nonisolated struct LibraryLocation {
    let root: URL

    static var documents: LibraryLocation {
        LibraryLocation(root: URL.documentsDirectory)
    }

    var trash: URL { root.appending(path: ".Trash", directoryHint: .isDirectory) }

    static let placeholderName = "About BetterNotes.txt"

    /// Creates the folders the app expects. Safe to call on every launch and
    /// from every window: existing files and folders are never touched.
    func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)

        // The Files app only lists an app's folder once Documents holds something
        // visible, and `.Trash` is hidden. So an empty library gets a small note.
        let visible = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        if visible.isEmpty {
            let note = "This folder is the BetterNotes library. Notebooks (.inkbook) and folders live here.\n"
                + "Do not delete the BetterNotes app from the iPad: that deletes everything in this folder.\n"
            try Data(note.utf8).write(
                to: root.appending(path: Self.placeholderName), options: .atomic)
        }
    }

    /// The notebooks directly in the library, sorted by name. (Milestone 5 adds folders.)
    func notebookURLs() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return (contents ?? [])
            .filter { $0.pathExtension == NotebookPackage.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
