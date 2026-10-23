import Foundation

/// Moves or copies pages, with their ink, from an open notebook into another notebook of the
/// library (SPEC, "Move or copy selected pages to another notebook").
///
/// The order is chosen so that no failure can lose pages:
/// 1. everything that can be checked is checked first, before anything changes;
/// 2. the pages are added to the target and the target is **saved and confirmed**;
/// 3. only then, for a move, are they removed from the source.
/// If step 2 fails, the source is untouched; if the app dies between 2 and 3, the pages
/// exist in both notebooks, which is a duplicate and not a loss.
///
/// The removal from the source is one undo step of the source notebook. Undoing it brings
/// the pages back there; the copies in the target stay (the target is another notebook with
/// its own history), so a move that is undone leaves the pages in both places.
@MainActor
enum PageTransfer {
    /// Adds copies of `ids` at the end of the notebook at `targetURL`. With `move`, the pages
    /// are then removed from `source`. The target must not be open in any window: that
    /// window's notebook would not know about the change and overwrite it.
    static func transfer(
        _ ids: Set<UUID>, from source: Notebook, toNotebookAt targetURL: URL, move: Bool,
        registry: OpenNotebookRegistry = .shared
    ) async throws {
        let sameFolder = { (a: URL, b: URL) in
            a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !sameFolder(source.package.url, targetURL) else { throw NotebookError.sameNotebook }
        guard source.document != nil else { throw NotebookError.pagesCannotBeChanged }
        let chosen = ids.intersection(source.pages.map(\.id))
        guard !chosen.isEmpty else { return }
        if move, chosen.count == source.pages.count { throw NotebookError.cannotDeleteAllPages }

        guard registry.claim(targetURL) else { throw NotebookError.alreadyOpen }
        defer { registry.release(targetURL) }

        let target = try Notebook.open(NotebookPackage(url: targetURL))
        guard target.document != nil else { throw NotebookError.pagesCannotBeChanged }

        let entries = try source.copyEntries(chosen)
        // Images first: the target's meta.json must never name a file it does not have.
        try target.package.copyObjectFiles(
            Set(entries.flatMap(\.meta.objects).compactMap(\.imageFile)), from: source.package)
        try target.insertPages(entries, at: target.pages.count, actionName: "Add Pages")
        await target.saveChanges()
        guard !target.hasUnsavedChanges else {
            throw TransferError.targetNotSaved(target.saveError ?? "unknown error")
        }

        if move { try source.deletePages(chosen) }
    }

    enum TransferError: LocalizedError {
        case targetNotSaved(String)

        var errorDescription: String? {
            switch self {
            case .targetNotSaved(let reason):
                "The pages could not be saved in the other notebook, so nothing was moved: \(reason)"
            }
        }
    }
}
