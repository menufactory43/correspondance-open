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

  func testLArretDuRelaisMessengerSeDitEnFrancais() {
    XCTAssertEqual(MatrixBridgeNotice.systemText(for: "Stopped relaying messages for users who haven't logged in"), "Relais du pont éteint : cc propose des brouillons, visibles de toi seul.")
  }

  func testUnRelaisDejaEteintSeDitEnFrancais() {
    XCTAssertEqual(MatrixBridgeNotice.systemText(for: "This portal doesn't have a relay set."), MatrixBridgeNotice.relayOffText)
    XCTAssertEqual(MatrixBridgeNotice.relayState(in: "This portal doesn't have a relay set."), false)
    XCTAssertEqual(MatrixBridgeNotice.relayState(in: "Messages … will now be relayed through +33"), true)
    XCTAssertNil(MatrixBridgeNotice.relayState(in: "Something else happened"))
    XCTAssertEqual(MatrixBridgeNotice.relayState(ofSystemText: MatrixBridgeNotice.relayOnText), true)
    XCTAssertNil(MatrixBridgeNotice.relayState(ofSystemText: "Pont : autre chose"))
  }

  func testUneCommandeAuPontEstReconnue() {
    XCTAssertTrue(MatrixBridgeNotice.isBridgeCommand("!wa set-relay", network: .whatsapp))
    XCTAssertTrue(MatrixBridgeNotice.isBridgeCommand("!signal unset-relay", network: .signal))
    XCTAssertFalse(MatrixBridgeNotice.isBridgeCommand("!wa set-relay", network: .signal), "le préfixe d'un autre réseau n'est qu'un texte")
    XCTAssertFalse(MatrixBridgeNotice.isBridgeCommand("salut !wa", network: .whatsapp))
  }
}
