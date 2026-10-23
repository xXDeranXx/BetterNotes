import Foundation
import Testing
@testable import BetterNotes

/// Tabs step 1: the registry knows which tab of which window has a notebook open.
struct OpenNotebookRegistryTests {
    private let one = URL(filePath: "/tmp/Library/One.inkbook")
    private let two = URL(filePath: "/tmp/Library/Two.inkbook")

    @Test func ownerIsRememberedUntilRelease() {
        let registry = OpenNotebookRegistry()
        let owner = NotebookOwner(window: UUID(), tab: UUID())
        #expect(registry.claim(one, by: owner))
        #expect(registry.owner(of: one) == owner)
        #expect(registry.owner(of: two) == nil)

        registry.release(one)
        #expect(registry.owner(of: one) == nil)
        #expect(!registry.isOpen(at: one))
    }

    @Test func aClaimedNotebookCannotBeClaimedByAnotherTab() {
        let registry = OpenNotebookRegistry()
        let first = NotebookOwner(window: UUID(), tab: UUID())
        #expect(registry.claim(one, by: first))
        #expect(!registry.claim(one, by: NotebookOwner(window: first.window, tab: UUID())))
        #expect(!registry.claim(one))
        #expect(registry.owner(of: one) == first)  // the failed claims changed nothing
    }

    @Test func aClaimWithoutOwnerCountsAsOpen() {
        let registry = OpenNotebookRegistry()
        #expect(registry.claim(one))
        #expect(registry.isOpen(at: one))
        #expect(registry.owner(of: one) == nil)
        #expect(!registry.claim(one, by: NotebookOwner(window: UUID(), tab: UUID())))
    }

    @Test func ownerIsFoundThroughAnotherPath() {
        let registry = OpenNotebookRegistry()
        let owner = NotebookOwner(window: UUID(), tab: UUID())
        #expect(registry.claim(one, by: owner))
        #expect(registry.owner(of: URL(filePath: "/tmp/Library/x/../One.inkbook")) == owner)
    }

    @Test func releaseAllFreesOnlyThatWindow() {
        let registry = OpenNotebookRegistry()
        let window = UUID()
        let other = NotebookOwner(window: UUID(), tab: UUID())
        let three = URL(filePath: "/tmp/Library/Three.inkbook")
        #expect(registry.claim(one, by: NotebookOwner(window: window, tab: UUID())))
        #expect(registry.claim(two, by: NotebookOwner(window: window, tab: UUID())))
        #expect(registry.claim(three, by: other))

        registry.releaseAll(ownedBy: window)

        #expect(!registry.isOpen(at: one))
        #expect(!registry.isOpen(at: two))
        #expect(registry.owner(of: three) == other)
    }

    @Test func aFolderIsOpenWhenANotebookInsideIsATab() {
        let registry = OpenNotebookRegistry()
        #expect(registry.claim(one, by: NotebookOwner(window: UUID(), tab: UUID())))
        #expect(registry.isOpen(at: URL(filePath: "/tmp/Library")))
        #expect(!registry.isOpen(at: URL(filePath: "/tmp/Lib")))
    }
}
