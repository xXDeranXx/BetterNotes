import Foundation

/// How much space notebooks and backups take. Sizes count what a backup would contain: the
/// `thumbnails/` cache of a notebook is a cache that can be rebuilt, so it is left out (SPEC,
/// "Export and backup"), as is the trash.
nonisolated enum StorageSize {
    /// Total size in bytes of the files below `url` (or of `url` itself if it is a file),
    /// without any folder named `thumbnails` and, at the top, `.Trash`. Hidden files count.
    static func bytes(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        }
        var total: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let name = item.lastPathComponent
                if name == "thumbnails" || (walker.level == 1 && name == ".Trash") { walker.skipDescendants() }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Free space on the iPad's storage, counting what iPadOS can free up by itself (the
    /// number Settings shows); `nil` if it cannot be read.
    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// "4.2 MB", "850 KB".
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `bytes(of:)` off the main thread, for views.
    static func measure(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) { bytes(of: url) }.value
    }
}
