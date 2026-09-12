import XCTest
@testable import NightScope

final class ViewHelperTests: XCTestCase {

    // MARK: - CalendarView.makeWeekdayHeaderItems

    func test_makeWeekdayHeaderItems_preservesLabelsAndUsesUniqueIDs() {
        let labels = ["S", "M", "T", "W", "T", "F", "S"]

        let items = CalendarView.makeWeekdayHeaderItems(from: labels)

        XCTAssertEqual(items.map(\.label), labels)
        XCTAssertEqual(items.map(\.id), Array(0..<labels.count))
        XCTAssertEqual(Set(items.map(\.id)).count, labels.count)
    }

    // MARK: - SearchResultsLayout.needsScroll

    func test_needsScroll_returnsFalseWhenResultsFitVisibleCapacity() {
        XCTAssertFalse(SearchResultsLayout.needsScroll(resultCount: 2, visibleRowCapacity: 2.5))
        XCTAssertFalse(SearchResultsLayout.needsScroll(resultCount: 3, visibleRowCapacity: 3.38))
    }

    func test_needsScroll_returnsTrueWhenResultsExceedVisibleCapacity() {
        XCTAssertTrue(SearchResultsLayout.needsScroll(resultCount: 3, visibleRowCapacity: 2.5))
        XCTAssertTrue(SearchResultsLayout.needsScroll(resultCount: 4, visibleRowCapacity: 3.38))
    }
}
