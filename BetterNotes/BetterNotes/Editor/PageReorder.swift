import Foundation

/// Where pages end up when they are dropped onto another page in the page grid.
nonisolated enum PageReorder {
    /// The `toIndex` for `Notebook.movePages(_:toIndex:)` when `moving` is dropped onto `target`.
    ///
    /// Dragging backward (to an earlier page) puts the pages before the target; dragging
    /// forward puts them after it. Otherwise the pages would always land one place short of
    /// where the finger let go. `nil` when the drop does nothing (onto one of the moving pages,
    /// or onto an unknown page).
    static func destination(order: [UUID], moving: Set<UUID>, onto target: UUID) -> Int? {
        guard !moving.contains(target), let targetIndex = order.firstIndex(of: target) else { return nil }
        let remaining = order.filter { !moving.contains($0) }
        guard let indexAmongRemaining = remaining.firstIndex(of: target) else { return nil }
        let isDraggedForward = order.firstIndex(where: moving.contains).map { $0 < targetIndex } ?? false
        return isDraggedForward ? indexAmongRemaining + 1 : indexAmongRemaining
    }
}
