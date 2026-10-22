import SwiftUI
import UIKit

/// A temporary file handed to the share sheet. Identifiable so `.sheet(item:)` can show it.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet (`UIActivityViewController`) for SwiftUI. UIKit has no SwiftUI
/// version for files, so it is wrapped: SwiftUI builds it once with `makeUIViewController`.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// `true` if the user really shared or saved the file, `false` if they cancelled.
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ExportFolderError: LocalizedError {
    case notChosen
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notChosen: "No export folder is chosen yet."
        case .unreachable: "The export folder cannot be reached any more. Choose it again."
        }
    }
}

/// The remembered export folder (for example a folder in the Obsidian vault), so the Files
/// picker is only needed once. The picker gives a URL that works for a short while; a
/// *bookmark* is a small piece of data that lets the app get access to the same folder again
/// later, even after a restart. It is device-specific, so it lives in `UserDefaults`, not in the
/// library.
enum ExportFolderStore {
    private static let key = "exportFolderBookmark"

    /// Remembers a folder the user just picked.
    static func remember(_ folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: key) }

    private static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        if isStale { try? remember(url) }
        return url
    }

    /// The folder's name for the buttons, or `nil` if none is chosen.
    static var folderName: String? { resolve()?.lastPathComponent }

    /// Copies `file` into the export folder. A name that is taken gets a number ("Name (2).pdf"),
    /// so an earlier export is never overwritten. Returns the name the copy got.
    static func save(_ file: URL) throws -> (folder: String, file: String) {
        guard UserDefaults.standard.data(forKey: key) != nil else { throw ExportFolderError.notChosen }
        guard let folder = resolve() else { throw ExportFolderError.unreachable }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }

        let target = LibraryOperations.uniqueURL(
            in: folder, baseName: file.deletingPathExtension().lastPathComponent, pathExtension: file.pathExtension)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: file, to: url) } catch { copyError = error }
        }
        if let error = copyError ?? coordinationError { throw error }
        return (folder.lastPathComponent, target.lastPathComponent)
    }
}
