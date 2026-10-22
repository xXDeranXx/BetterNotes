import Foundation
import PencilKit
@testable import BetterNotes

// Helpers shared by the test files.

/// A fresh temporary folder that is removed when the test ends.
final class TempFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // A test may leave a folder read-only on purpose; make it deletable again.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

func makeNotebook(
    in parent: URL, title: String = "Test", template: PageTemplate = .lined,
    size: PageSize = .a4Portrait
) throws -> NotebookPackage {
    try NotebookPackage.create(
        in: parent, title: title, template: template, size: size, coverColor: "#3366CC")
}

func sampleDrawing(offset: CGFloat = 0) -> PKDrawing {
    let points = [
        PKStrokePoint(location: CGPoint(x: 10 + offset, y: 10), timeOffset: 0, size: CGSize(width: 4, height: 4),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        PKStrokePoint(location: CGPoint(x: 100 + offset, y: 80), timeOffset: 0.1, size: CGSize(width: 4, height: 4),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
    ]
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_700_000_000))
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
}

/// A straight pen stroke between two points in page coordinates.
func lineDrawing(from start: CGPoint, to end: CGPoint, width: CGFloat = 6) -> PKDrawing {
    let size = CGSize(width: width, height: width)
    let points = [
        PKStrokePoint(location: start, timeOffset: 0, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        PKStrokePoint(location: end, timeOffset: 0.1, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
    ]
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_700_000_000))
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
}

/// Pixel colors of an image, to check what a render actually contains.
struct PixelReader {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: UIImage) {
        let cgImage = image.cgImage!
        width = cgImage.width
        height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    /// Red, green and blue (0...255) of the pixel at x, y; y counts from the top.
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func isDark(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r < 80 && c.g < 80 && c.b < 80 }
    func isWhite(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r > 245 && c.g > 245 && c.b > 245 }
}
