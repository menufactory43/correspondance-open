import XCTest
@testable import CorrespondanceCore

/// Le rapatriement d'un compte fraîchement connecté : quand l'inbox retient
/// les fils, et quand elle les lâche tous ensemble.
final class BridgeIntakeTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_756_400_000)

  func testArrivalsResetTheQuietClockAndFillTheBar() {
    var intake = BridgeIntake(network: .telegram, startedAt: t0, expectedCount: 30)
    XCTAssertEqual(intake.progress, 0)
    XCTAssertEqual(intake.countLabelFR, "Le pont relit tes conversations…")
    intake.observe(count: 3, at: t0.addingTimeInterval(5))
    XCTAssertEqual(intake.lastArrivalAt, t0.addingTimeInterval(5))
    XCTAssertEqual(intake.progress, 0.1, accuracy: 0.001)
    XCTAssertEqual(intake.countLabelFR, "3 fils rapatriés")
    // Le même compte ne relance pas l'horloge.
    intake.observe(count: 3, at: t0.addingTimeInterval(9))
    XCTAssertEqual(intake.lastArrivalAt, t0.addingTimeInterval(5))
    intake.observe(count: 45, at: t0.addingTimeInterval(20))
    XCTAssertEqual(intake.progress, 1)
  }

  func testSettlesAfterAQuietPeriodOnceSomethingArrived() {
    var intake = BridgeIntake(network: .telegram, startedAt: t0)
    intake.observe(count: 1, at: t0.addingTimeInterval(4))
    XCTAssertEqual(intake.countLabelFR, "Un fil rapatrié")
    XCTAssertFalse(intake.isSettled(at: t0.addingTimeInterval(4 + BridgeIntake.quietPeriod - 1)))
    XCTAssertTrue(intake.isSettled(at: t0.addingTimeInterval(4 + BridgeIntake.quietPeriod)))
  }

  /// Tant que le pont se dit lui-même en rapatriement, on attend — sauf
  /// au-delà de la patience maximale.
  func testBridgeStateKeepsHoldingUntilTheHardLimit() {
    var intake = BridgeIntake(network: .slack, startedAt: t0)
    intake.observe(count: 8, at: t0.addingTimeInterval(4))
    let later = t0.addingTimeInterval(60)
    XCTAssertTrue(intake.isSettled(at: later))
    XCTAssertFalse(intake.isSettled(at: later, bridgeState: "BACKFILLING"))
    XCTAssertTrue(intake.isSettled(at: later, bridgeState: "CONNECTED"))
    XCTAssertTrue(intake.isSettled(at: t0.addingTimeInterval(BridgeIntake.maxDuration), bridgeState: "BACKFILLING"))
  }

  /// Rien n'arrive : on ne retient pas une inbox vide pour toujours.
  func testGivesUpWhenNothingEverArrives() {
    let intake = BridgeIntake(network: .telegram, startedAt: t0)
    XCTAssertFalse(intake.isSettled(at: t0.addingTimeInterval(BridgeIntake.emptyPatience - 1)))
    XCTAssertTrue(intake.isSettled(at: t0.addingTimeInterval(BridgeIntake.emptyPatience)))
  }
}
