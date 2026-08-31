import XCTest
@testable import CorrespondanceCore

final class MessageArrivalPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testUnMessageEcritALInstantArrive() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-5), now: now))
  }

  func testUnMessageDateDansLeFuturArriveAussi() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(30), now: now))
  }

  func testUnMessageDHierEstDejaVu() {
    XCTAssertFalse(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-86_400), now: now))
  }

  func testLaCoupureEstADeuxMinutes() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-119), now: now))
    XCTAssertFalse(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-121), now: now))
  }
}
