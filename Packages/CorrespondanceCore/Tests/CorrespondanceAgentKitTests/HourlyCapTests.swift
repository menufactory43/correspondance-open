import XCTest
@testable import CorrespondanceAgentKit

final class HourlyCapTests: XCTestCase {
  func testAdmitsUpToLimitThenRefuses() {
    var cap = HourlyCap(limit: 2, window: 3600)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertTrue(cap.admit(now: t0))
    XCTAssertTrue(cap.admit(now: t0.addingTimeInterval(1)))
    XCTAssertFalse(cap.admit(now: t0.addingTimeInterval(2)))
    XCTAssertEqual(cap.remaining(now: t0.addingTimeInterval(2)), 0)
    XCTAssertEqual(cap.nextSlot(now: t0.addingTimeInterval(2)).map { Int($0) }, 3598)
  }

  func testWindowSlides() {
    var cap = HourlyCap(limit: 1, window: 60)
    let t0 = Date(timeIntervalSince1970: 0)
    XCTAssertTrue(cap.admit(now: t0))
    XCTAssertFalse(cap.admit(now: t0.addingTimeInterval(59)))
    XCTAssertTrue(cap.admit(now: t0.addingTimeInterval(60)))
    XCTAssertNil(cap.nextSlot(now: t0.addingTimeInterval(121)))
  }
}
