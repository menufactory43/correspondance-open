import XCTest

@testable import CorrespondanceCore

/// Le bot d'un pont parle anglais dans le portail ; le fil le dit en
/// français, en ligne d'événement, et ne se tait jamais sur un avis inconnu.
final class MatrixBridgeNoticeTests: XCTestCase {
  func testLeRelaisAllumeSeDitEnFrancais() {
    let body = "Messages sent by users who haven't logged in will now be relayed through +33699000001 (@meffysto:correspondance.local's login)"
    XCTAssertEqual(MatrixBridgeNotice.systemText(for: body), "Relais du pont allumé : cc parle ici à voix haute, depuis ton compte.")
  }

  func testLeRelaisEteintSeDitEnFrancais() {
    XCTAssertEqual(MatrixBridgeNotice.systemText(for: "Relay user unset"), "Relais du pont éteint : cc propose des brouillons, visibles de toi seul.")
  }

  func testUnMessageNonRelayeGardeLaRaison() {
    let body = "⚠️ Your message was not bridged: You're not logged in (relay not set)"
    XCTAssertTrue(MatrixBridgeNotice.systemText(for: body).hasPrefix("Message non relayé par le pont : "))
    XCTAssertTrue(MatrixBridgeNotice.systemText(for: body).contains("relay not set"))
  }

  func testUnAvisInconnuNEstPasAvale() {
    XCTAssertEqual(MatrixBridgeNotice.systemText(for: "Something else happened"), "Pont : Something else happened")
  }
}
