import Foundation

/// True while a window animates between the library and a notebook. Background work that
/// draws on the main thread (page thumbnails, library covers) waits for it to be false, so it
/// does not compete with the animation for frames. Like a "busy" flag in a React store, but
/// shared by all windows on purpose: it only ever delays optional work by a moment.
enum TransitionGate {
    static var isActive = false

    /// Returns as soon as no transition runs, or after one second at most.
    static func waitUntilIdle() async {
        var waited = 0
        while isActive && waited < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }
}
