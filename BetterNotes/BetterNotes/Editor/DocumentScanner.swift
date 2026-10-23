import SwiftUI
import VisionKit

/// Apple's document camera (VisionKit): it finds the sheet of paper, straightens it and
/// lets the user take several pages. Wrapped for SwiftUI with `UIViewControllerRepresentable`,
/// like `PDFView` in the editor.
///
/// When the user taps Save, `close` is called at once (the camera goes away), then the
/// pages are shrunk and compressed (`ScanPages.jpegData`) in the background, one at a time,
/// so a dozen 12-megapixel photos are never all in memory. `finish` gets the JPEGs on the
/// main thread; an empty array means the user cancelled.
struct DocumentScanner: UIViewControllerRepresentable {
    let close: () -> Void
    let finish: (Result<[Data], Error>) -> Void

    /// False in the simulator (no camera) and on devices without one.
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    /// Shown instead of the camera where there is none (the simulator).
    static let unavailableMessage = "Scanning needs the iPad's camera. It is not available here."

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ camera: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(close: close, finish: finish) }

    /// The camera reports through a delegate (an object with callback methods, like passing
    /// `onSave` / `onCancel` props in React). The coordinator is that object.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let close: () -> Void
        let finish: (Result<[Data], Error>) -> Void
        init(close: @escaping () -> Void, finish: @escaping (Result<[Data], Error>) -> Void) {
            self.close = close
            self.finish = finish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            close()
            let finish = finish
            // The scan object is only read here, never shared further.
            nonisolated(unsafe) let scan = scan
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<[Data], Error> in
                    Result {
                        try (0..<scan.pageCount).map { index in
                            try autoreleasepool { try ScanPages.jpegData(for: scan.imageOfPage(at: index)) }
                        }
                    }
                }.value
                finish(result)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            close()
            finish(.success([]))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            close()
            finish(.failure(error))
        }
    }
}

extension View {
    /// Shows the document camera full screen while `isPresented` is true. `scanned` gets the
    /// compressed pages (never called for a cancel); `failed` gets a message to show.
    func documentScanner(
        isPresented: Binding<Bool>, scanned: @escaping ([Data]) -> Void, failed: @escaping (String) -> Void
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            DocumentScanner(close: { isPresented.wrappedValue = false }) { result in
                switch result {
                case .success(let jpegs): if !jpegs.isEmpty { scanned(jpegs) }
                case .failure(let error): failed(error.localizedDescription)
                }
            }
            .ignoresSafeArea()
        }
    }
}
