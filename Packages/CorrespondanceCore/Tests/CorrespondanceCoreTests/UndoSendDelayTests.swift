import XCTest
@testable import CorrespondanceCore

final class UndoSendDelayTests: XCTestCase {
  func testLeDefautEstCinqSecondes() {
    XCTAssertEqual(UndoSendDelay.fallback, .five)
    XCTAssertEqual(UndoSendDelay.fallback.seconds, 5)
  }

  func testDesactiveNEstPasUnDelaiNul() {
    XCTAssertFalse(UndoSendDelay.off.isOn)
    XCTAssertTrue(UndoSendDelay.three.isOn)
  }

  /// Un réglage écrit par une version antérieure ne doit pas couper le geste.
  func testUneValeurInconnueRetombeSurLeDefaut() {
    XCTAssertEqual(UndoSendDelay.fromStored(nil), .five)
    XCTAssertEqual(UndoSendDelay.fromStored(7), .five)
    XCTAssertEqual(UndoSendDelay.fromStored(0), .off)
    XCTAssertEqual(UndoSendDelay.fromStored(10), .ten)
  }

  func testLesQuatreChoixSontDansLOrdre() {
    XCTAssertEqual(UndoSendDelay.allCases.map(\.rawValue), [0, 3, 5, 10])
  }
}
