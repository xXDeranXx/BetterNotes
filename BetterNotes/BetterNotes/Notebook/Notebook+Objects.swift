import Foundation

/// Changes to images and text boxes (SPEC, "Objects on pages"). Each one is a single undo step
/// through `setObjects`, the one place where objects change.
extension Notebook {
    /// Puts a new object on top of the page's other objects (still below the ink).
    func addObject(_ object: PageObject, to pageID: UUID, actionName: String) {
        setObjects(objects(on: pageID) + [object], for: pageID, actionName: actionName)
    }

    /// Replaces the object with the same id (moved, resized, edited). Nothing happens if the
    /// page has no such object.
    func updateObject(_ object: PageObject, on pageID: UUID, actionName: String) {
        var list = objects(on: pageID)
        guard let index = list.firstIndex(where: { $0.id == object.id }) else { return }
        list[index] = object
        setObjects(list, for: pageID, actionName: actionName)
    }

    /// Removes objects from a page. Image files stay on disk: undo can bring the object back.
    func removeObjects(_ ids: Set<UUID>, from pageID: UUID) {
        let list = objects(on: pageID)
        let remaining = list.filter { !ids.contains($0.id) }
        guard remaining.count != list.count else { return }
        let count = list.count - remaining.count
        setObjects(remaining, for: pageID, actionName: count == 1 ? "Delete Object" : "Delete Objects")
    }

    /// Image files used by objects on the given pages.
    func imageFiles(onPages pageIDs: Set<UUID>) -> Set<String> {
        Set(pages.filter { pageIDs.contains($0.id) }.flatMap(\.objects).compactMap(\.imageFile))
    }
}
