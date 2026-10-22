import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import BetterNotes

/// Writes a PDF with `pageCount` pages of `size` into `folder`. Each page has a dark square
/// at its top-left so renders can tell the pages apart from blank ones.
func makeSamplePDF(
    in folder: URL, name: String = "sample.pdf", pageCount: Int,
    size: CGSize = CGSize(width: 595, height: 842)
) throws -> URL {
    let url = folder.appending(path: name)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
    try renderer.writePDF(to: url) { context in
        for _ in 0..<pageCount {
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
    }
    return url
}

@Suite struct PDFImportTests {
    @Test func importCopiesThePDFAndDescribesEveryPage() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 3)
        let library = temp.url.appending(path: "library")

        let package = try NotebookPackage.importPDF(
            from: source, in: library, title: "Lecture", coverColor: "#112233")

        let meta = try package.readMeta()
        #expect(meta.title == "Lecture")
        #expect(meta.pages.count == 3)
        #expect(Set(meta.pages.map(\.id)).count == 3)  // ids are unique
        #expect(meta.pages.allSatisfy { $0.template == .pdf && $0.rotation == 0 })
        #expect(meta.pages.allSatisfy { $0.size == PageSize(width: 595, height: 842) })
        #expect(PDFDocument(url: package.pdfURL)?.pageCount == 3)
        #expect(try Data(contentsOf: package.pdfURL) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: source.path))  // original untouched
        #expect(package.url.pathExtension == "inkbook")
    }

    @Test @MainActor func importedNotebookOpensAndHasNoInkYet() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 2)
        let package = try NotebookPackage.importPDF(
            from: source, in: temp.url.appending(path: "library"), title: "Slides", coverColor: "#000000")

        let notebook = try Notebook.open(package)

        #expect(notebook.pages.count == 2)
        #expect(notebook.drawing(for: notebook.pages[0].id).strokes.isEmpty)
    }

    @Test func pageSizeFollowsTheCropBoxNotTheMediaBox() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 1)
        let document = try #require(PDFDocument(url: source))
        try #require(document.page(at: 0)).setBounds(CGRect(x: 30, y: 40, width: 400, height: 500), for: .cropBox)
        let cropped = temp.url.appending(path: "cropped.pdf")
        #expect(document.write(to: cropped))

        let pages = try NotebookPackage.readPages(of: cropped)

        #expect(pages[0].size == PageSize(width: 400, height: 500))
    }

    @Test func rotatedPagesReportTheirDisplayedSize() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 2)
        let document = try #require(PDFDocument(url: source))
        try #require(document.page(at: 1)).rotation = 90
        let rotated = temp.url.appending(path: "rotated.pdf")
        #expect(document.write(to: rotated))

        let pages = try NotebookPackage.readPages(of: rotated)

        #expect(pages[0].size == PageSize(width: 595, height: 842))
        #expect(pages[0].rotation == 0)
        #expect(pages[1].size == PageSize(width: 842, height: 595))  // turned on its side
        #expect(pages[1].rotation == 90)
    }

    @Test func importedPagesKeepTheirOrder() throws {
        let temp = try TempFolder()
        // Different sizes per page make the order observable.
        let url = temp.url.appending(path: "mixed.pdf")
        let sizes = [CGSize(width: 300, height: 400), CGSize(width: 500, height: 200), CGSize(width: 250, height: 250)]
        let renderer = UIGraphicsPDFRenderer()
        try renderer.writePDF(to: url) { context in
            for size in sizes { context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:]) }
        }

        let pages = try NotebookPackage.readPages(of: url)

        #expect(pages.map(\.size) == sizes.map { PageSize(width: $0.width, height: $0.height) })
    }

    @Test func aFileThatIsNotAPDFIsRefusedAndLeavesNothingBehind() throws {
        let temp = try TempFolder()
        let bogus = temp.url.appending(path: "bogus.pdf")
        try Data("not a pdf".utf8).write(to: bogus)
        let library = temp.url.appending(path: "library")

        #expect(throws: NotebookError.pdfUnreadable) {
            try NotebookPackage.importPDF(from: bogus, in: library, title: "Bogus", coverColor: "#000000")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func aPasswordProtectedPDFIsRefused() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "locked.pdf")
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            format: {
                let format = UIGraphicsPDFRendererFormat()
                format.documentInfo = [
                    kCGPDFContextUserPassword as String: "secret",
                    kCGPDFContextOwnerPassword as String: "secret",
                ]
                return format
            }())
        try renderer.writePDF(to: url) { $0.beginPage() }

        #expect(throws: NotebookError.pdfPasswordProtected) {
            try NotebookPackage.importPDF(
                from: url, in: temp.url.appending(path: "library"), title: "Locked", coverColor: "#000000")
        }
    }

    @Test func importingTheSameFileTwiceMakesTwoNotebooks() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 1)
        let library = temp.url.appending(path: "library")

        let first = try NotebookPackage.importPDF(from: source, in: library, title: "Same", coverColor: "#000000")
        let second = try NotebookPackage.importPDF(from: source, in: library, title: "Same", coverColor: "#000000")

        #expect(first.url != second.url)
        #expect(second.url.lastPathComponent == "Same 2.inkbook")
    }

    @Test func titleComesFromTheFileName() {
        #expect(NotebookPackage.title(forImportedFile: URL(filePath: "/x/Analysis Lecture 3.pdf")) == "Analysis Lecture 3")
    }

    @Test func aLargePDFImportsQuickly() throws {
        let temp = try TempFolder()
        let source = try makeSamplePDF(in: temp.url, pageCount: 300)

        let started = ContinuousClock.now
        let package = try NotebookPackage.importPDF(
            from: source, in: temp.url.appending(path: "library"), title: "Big", coverColor: "#000000")
        let elapsed = ContinuousClock.now - started

        #expect(try package.readMeta().pages.count == 300)
        #expect(elapsed < .seconds(5))
    }
}
