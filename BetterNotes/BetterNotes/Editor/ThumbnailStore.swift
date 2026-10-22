import PDFKit
import UIKit

/// Page pictures for the sidebar and the page grid (SPEC, "Page thumbnails show the page with
/// its ink (rendered in the background and cached)"). They come from `PageRenderer`, the one
/// page renderer, so ink and rotation look the same as everywhere else.
///
/// Two caches: pictures in memory, and JPEG files in the notebook's `thumbnails/` folder (a
/// cache that may be deleted any time, SPEC "File format"). A picture is out of date when the
/// page's ink changed (`Notebook.revisions`) or the page was turned; both are part of the key.
///
/// PDFKit pages are not made for other threads, so rendering happens on the main thread, one
/// picture at a time with a pause in between, and slows down when the iPad gets hot.
final class ThumbnailStore {
    /// Output pixels per page point: about 300 pixels for an A4 page, sharp at 150 points wide.
    static let scale: CGFloat = 0.5

    private let notebook: Notebook
    private let cache = NSCache<NSString, UIImage>()
    /// How many pictures were actually drawn (not served from a cache); tests read this.
    private(set) var renderCount = 0

    init(notebook: Notebook) {
        self.notebook = notebook
        cache.countLimit = 300
    }

    private func revision(of page: PageMeta) -> Int { notebook.revisions[page.id, default: 0] }

    /// Changes whenever the picture would look different. Views use it as the identity of the
    /// work to do, so a change cancels the old render and starts a new one.
    func key(for page: PageMeta) -> String {
        "\(page.id.uuidString)-r\(page.rotation)-v\(revision(of: page))"
    }

    func image(for page: PageMeta) async -> UIImage? {
        let key = key(for: page)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        // Without changes in this session the file on disk may still be right.
        if revision(of: page) == 0, let stored = loadFromDisk(page) {
            cache.setObject(stored, forKey: key as NSString)
            return stored
        }

        await Task.yield()  // let the interface draw between two pictures
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            try? await Task.sleep(for: .seconds(1))  // SPEC: background work slows down when hot
        }
        guard !Task.isCancelled else { return nil }
        // The list may have changed while waiting; look the page up again.
        guard let index = notebook.pages.firstIndex(where: { $0.id == page.id }),
            let pdfPage = notebook.document?.page(at: index)
        else { return nil }

        let image = PageRenderer.render(
            page: pdfPage, drawing: notebook.drawing(for: page.id), scale: Self.scale)
        renderCount += 1
        cache.setObject(image, forKey: key as NSString)
        saveToDisk(image, for: page)
        notebook.evictOffscreenDrawings()  // a thumbnail must not keep the page's ink in memory
        return image
    }

    // MARK: Disk cache

    private func fileURL(for page: PageMeta) -> URL {
        notebook.package.url.appending(path: "thumbnails/\(page.id.uuidString)-r\(page.rotation).jpg")
    }

    /// Valid when it is not older than the page's saved drawing.
    private func loadFromDisk(_ page: PageMeta) -> UIImage? {
        let url = fileURL(for: page)
        let fileManager = FileManager.default
        guard let thumbnailDate = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        let drawingPath = notebook.package.drawingURL(for: page.id).path
        if let drawingDate = (try? fileManager.attributesOfItem(atPath: drawingPath))?[.modificationDate] as? Date,
            drawingDate > thumbnailDate
        { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func saveToDisk(_ image: UIImage, for page: PageMeta) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let url = fileURL(for: page)
        Task.detached(priority: .background) {
            // A cache: if this fails, the picture is simply drawn again next time.
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
