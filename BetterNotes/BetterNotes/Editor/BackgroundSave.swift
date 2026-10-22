import UIKit

/// Saves a notebook when the app leaves the foreground, and asks iPadOS for a little extra
/// time so the app is not suspended in the middle of a write.
@MainActor
enum BackgroundSave {
    private final class TaskIDBox {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    static func flush(_ notebook: Notebook) {
        let box = TaskIDBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "Save notebook") {
            // iPadOS is out of patience: end the task, the next foreground save continues.
            UIApplication.shared.endBackgroundTask(box.id)
        }
        Task {
            await notebook.saveChanges()
            UIApplication.shared.endBackgroundTask(box.id)
        }
    }
}
