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

    /// Creates the folders the app expects. Safe to call on every launch and
    /// from every window: existing files and folders are never touched.
    func prepare() throws {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }
}
