import XCTest
@testable import CorrespondanceCore

final class BubbleShapeTests: XCTestCase {
  func testUneBulleSeuleGardeSesQuatreRayons() {
    let corners = BubbleShape.corners(isFromMe: false, position: .alone, radius: 18)
    XCTAssertEqual(corners, BubbleCorners(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18))
  }

  func testMesBullesEnchainentParLaDroite() {
    let first = BubbleShape.corners(isFromMe: true, position: .first, radius: 18)
    XCTAssertEqual(first.bottomTrailing, BubbleShape.tightRadius)
    XCTAssertEqual(first.topTrailing, 18)
    XCTAssertEqual(first.topLeading, 18)
    XCTAssertEqual(first.bottomLeading, 18)

    let middle = BubbleShape.corners(isFromMe: true, position: .middle, radius: 18)
    XCTAssertEqual(middle.topTrailing, BubbleShape.tightRadius)
    XCTAssertEqual(middle.bottomTrailing, BubbleShape.tightRadius)

    let last = BubbleShape.corners(isFromMe: true, position: .last, radius: 18)
    XCTAssertEqual(last.topTrailing, BubbleShape.tightRadius)
    XCTAssertEqual(last.bottomTrailing, 18)
  }

  func testLesBullesRecuesEnchainentParLaGauche() {
    let middle = BubbleShape.corners(isFromMe: false, position: .middle, radius: 14)
    XCTAssertEqual(middle.topLeading, BubbleShape.tightRadius)
    XCTAssertEqual(middle.bottomLeading, BubbleShape.tightRadius)
    XCTAssertEqual(middle.topTrailing, 14)
    XCTAssertEqual(middle.bottomTrailing, 14)
  }

  func testLaPlaceSeDeduitDeLIndex() {
    XCTAssertEqual(BubblePosition(index: 0, count: 1), .alone)
    XCTAssertEqual(BubblePosition(index: 0, count: 3), .first)
    XCTAssertEqual(BubblePosition(index: 1, count: 3), .middle)
    XCTAssertEqual(BubblePosition(index: 2, count: 3), .last)
  }
}
