import Foundation
import Testing
@testable import BetterNotes

struct PageReorderTests {
    private let ids = (0..<5).map { _ in UUID() }  // pages 0...4

    /// The order that results from applying the destination to the plain list.
    private func result(moving: Set<Int>, onto target: Int) -> [Int]? {
        let movingIDs = Set(moving.map { ids[$0] })
        guard let index = PageReorder.destination(order: ids, moving: movingIDs, onto: ids[target]) else { return nil }
        let staying = (0..<5).filter { !moving.contains($0) }
        let block = (0..<5).filter { moving.contains($0) }
        return Array(staying[..<index]) + block + Array(staying[index...])
    }

    @Test func draggingBackwardLandsBeforeTheTarget() {
        #expect(result(moving: [3], onto: 1) == [0, 3, 1, 2, 4])
    }

    @Test func draggingForwardLandsAfterTheTarget() {
        #expect(result(moving: [1], onto: 3) == [0, 2, 3, 1, 4])
    }

    @Test func draggingOntoTheLastPageMakesItLast() {
        #expect(result(moving: [0], onto: 4) == [1, 2, 3, 4, 0])
    }

    @Test func draggingOntoTheFirstPageMakesItFirst() {
        #expect(result(moving: [4], onto: 0) == [4, 0, 1, 2, 3])
    }

    @Test func severalPagesKeepTheirOrderAsABlock() {
        #expect(result(moving: [0, 1], onto: 3) == [2, 3, 0, 1, 4])
        #expect(result(moving: [3, 4], onto: 0) == [3, 4, 0, 1, 2])
    }

    @Test func droppingOntoOneOfTheMovingPagesOrAnUnknownPageDoesNothing() {
        #expect(result(moving: [1, 2], onto: 2) == nil)
        #expect(PageReorder.destination(order: ids, moving: [ids[0]], onto: UUID()) == nil)
    }
}
