import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceCore

/// Un cadenas qui ment est pire que pas de cadenas. Ces tests tiennent la seule
/// chose qui doive être juste avant d'écrire la moindre ligne de cryptographie.
final class ConversationPrivacyTests: XCTestCase {

  func testUneRoomNativeChiffreeEstChiffreeDeBoutEnBout() {
    XCTAssertEqual(
      ConversationPrivacy.of(isBridged: false, encryptionAlgorithm: "m.megolm.v1.aes-sha2"),
      .chiffree
    )
  }

  func testUneRoomNativeEnClairLeDit() {
    XCTAssertEqual(ConversationPrivacy.of(isBridged: false, encryptionAlgorithm: nil), .relaisSeul)
    XCTAssertEqual(ConversationPrivacy.of(isBridged: false, encryptionAlgorithm: ""), .relaisSeul)
  }

  /// Le cas qui compte : un portail marqué chiffré reste lu par son pont.
  func testUnPortailMarqueChiffreNEstPasChiffreDeBoutEnBout() {
    XCTAssertEqual(
      ConversationPrivacy.of(isBridged: true, encryptionAlgorithm: "m.megolm.v1.aes-sha2"),
      .pontee,
      "le pont déchiffre par construction — la marque Matrix ne dit rien du réseau d'origine"
    )
  }

  func testUnAlgorithmeInconnuNEstPasUneGarantie() {
    XCTAssertEqual(
      ConversationPrivacy.of(isBridged: false, encryptionAlgorithm: "m.quelque.chose.v9"),
      .relaisSeul,
      "on ne promet que ce qu'on sait déchiffrer"
    )
  }

  func testSeuleLaConversationChiffreeMontreLeCadenas() {
    XCTAssertTrue(ConversationPrivacy.chiffree.showsClosedLock)
    XCTAssertFalse(ConversationPrivacy.relaisSeul.showsClosedLock)
    XCTAssertFalse(ConversationPrivacy.pontee.showsClosedLock)
  }

  func testChaqueEtatSExpliqueSansPromettreTrop() {
    for etat in ConversationPrivacy.allCases {
      XCTAssertFalse(etat.labelFR.isEmpty)
      XCTAssertFalse(etat.explanationFR.isEmpty)
    }
    XCTAssertTrue(
      ConversationPrivacy.relaisSeul.explanationFR.contains("peut lire"),
      "« chiffré jusqu'au Relais » doit dire qui lit"
    )
    XCTAssertTrue(
      ConversationPrivacy.pontee.explanationFR.contains("les lit au passage"),
      "un pont lit : ça se dit, ça ne se tait pas"
    )
  }

  func testLEtatDeLaRoomSuffitADecider() {
    let etat = [
      MatrixEvent(
        type: "m.room.encryption", eventID: "$e", sender: "@g:s", originServerTS: 0,
        content: .object(["algorithm": .string("m.megolm.v1.aes-sha2")])
      )
    ]
    XCTAssertEqual(ConversationPrivacy.of(isBridged: false, state: etat), .chiffree)
    XCTAssertEqual(ConversationPrivacy.of(isBridged: true, state: etat), .pontee)
    XCTAssertEqual(ConversationPrivacy.of(isBridged: false, state: []), .relaisSeul)
  }
}
