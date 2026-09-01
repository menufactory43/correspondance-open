import XCTest
@testable import CorrespondanceCore
import CorrespondanceMatrixClient

final class VoiceHoldGestureTests: XCTestCase {
  func testUnPouceQuiTrembleNAbandonnePas() {
    XCTAssertEqual(VoiceHoldGesture.outcome(translation: CGSize(width: -20, height: -12)), .recording)
  }

  func testGlisserAGaucheAnnule() {
    XCTAssertEqual(VoiceHoldGesture.outcome(translation: CGSize(width: -90, height: -4)), .cancelled)
  }

  func testGlisserVersLeHautVerrouille() {
    XCTAssertEqual(VoiceHoldGesture.outcome(translation: CGSize(width: -6, height: -100)), .locked)
  }

  func testLaDiagonaleTrancheParLePlusGrandEcart() {
    XCTAssertEqual(VoiceHoldGesture.outcome(translation: CGSize(width: -120, height: -85)), .cancelled)
    XCTAssertEqual(VoiceHoldGesture.outcome(translation: CGSize(width: -85, height: -120)), .locked)
  }

  func testLesTroisAlluresTournentEnRond() {
    XCTAssertEqual(PlaybackSpeed.normale.next, .rapide)
    XCTAssertEqual(PlaybackSpeed.rapide.next, .double)
    XCTAssertEqual(PlaybackSpeed.double.next, .normale)
  }

  func testLAllureSEcritALaFrancaise() {
    XCTAssertEqual(PlaybackSpeed.normale.label, "1×")
    XCTAssertEqual(PlaybackSpeed.rapide.label, "1,5×")
    XCTAssertEqual(PlaybackSpeed.double.label, "2×")
  }
}
