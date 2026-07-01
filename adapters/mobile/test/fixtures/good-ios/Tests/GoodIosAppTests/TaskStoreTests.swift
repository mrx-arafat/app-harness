import XCTest
@testable import GoodIosApp

final class TaskStoreTests: XCTestCase {
    func testRemainingCountsUndoneItems() {
        let store = TaskStore()
        XCTAssertEqual(store.remaining, 2)
    }

    func testToggleFlipsDoneState() {
        var store = TaskStore()
        store.toggle("t1")
        XCTAssertEqual(store.remaining, 1)
    }

    func testSummaryReportsAllClearWhenEmptyOfUndone() {
        var store = TaskStore(items: [TaskItem(id: "t1", title: "Only", isDone: true)])
        XCTAssertEqual(store.summary, "All clear")
        store.toggle("t1")
        XCTAssertEqual(store.summary, "1 left")
    }
}
