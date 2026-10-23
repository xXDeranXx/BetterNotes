import PDFKit
import PencilKit
import UIKit

/// The picture on a notebook tile: page 1 with its ink, drawn by `PageRenderer` (the one page
/// renderer). Cached in memory and as `thumbnails/cover.jpg` inside the notebook (a cache,
/// deletable any time). The file is reused while it is not older than `meta.json`, which
/// every save of the notebook rewrites.
///
/// PDFKit pages are not made for other threads, so drawing happens on the main thread, one
/// picture at a time, and slows down when the iPad gets hot (like `ThumbnailStore`).
final class CoverStore {
    static let shared = CoverStore()
    /// About 400 pixels wide for an A4 page, sharp on a 200-point tile.
    static let scale: CGFloat = 0.7

    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 200 }

    func image(for notebook: NotebookSummary) async -> UIImage? {
        guard notebook.problem == nil else { return nil }
        let key = "\(notebook.url.path)|\(notebook.updatedAt.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let package = NotebookPackage(url: notebook.url)
        let file = package.url.appending(path: "thumbnails/cover.jpg")
        if let stored = loadFromDisk(file, package: package) {
            cache.setObject(stored, forKey: key)
            return stored
        }

        await Task.yield()
        await TransitionGate.waitUntilIdle()
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled else { return nil }
        guard let meta = try? package.readMeta(), let first = meta.pages.first,
            let page = PDFDocument(url: package.pdfURL)?.page(at: 0)
        else { return nil }
        let drawing = (try? package.loadDrawing(for: first.id)) ?? nil
        let images = ObjectImageSource(package: package)
        // A whiteboard shows the area around its ink, never the whole 10000 pt board at page scale.
        let image = meta.isWhiteboard
            ? PageRenderer.renderBoardPreview(
                page: first, background: meta.boardBackground ?? .plain, drawing: drawing ?? .init(), images: images,
                width: PageSize.a4Portrait.width * Self.scale, maximumScale: Self.scale)
            : PageRenderer.render(page: page, drawing: drawing ?? .init(), objects: first.objects, images: images, scale: Self.scale)
        cache.setObject(image, forKey: key)
        if let data = image.jpegData(compressionQuality: 0.8) {
            Task.detached(priority: .background) {
                // A cache: if this fails the picture is simply drawn again next time.
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
        return image
    }

    private func loadFromDisk(_ file: URL, package: NotebookPackage) -> UIImage? {
        let fileManager = FileManager.default
        guard let coverDate = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
            let metaDate = (try? fileManager.attributesOfItem(atPath: package.metaURL.path))?[.modificationDate] as? Date,
            coverDate >= metaDate
        else { return nil }
        return UIImage(contentsOfFile: file.path)
    }
}
