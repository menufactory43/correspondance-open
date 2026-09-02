import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceCore

/// Les trois états, tels que l'écran les montre. La règle qu'aucun de ces tests
/// n'a le droit de laisser tomber : **un portail ne montre jamais le cadenas du
/// bout en bout.**
final class ConfidentialiteAfficheeTests: XCTestCase {

  private func conversation(
    _ reseau: MessageNetwork, algorithme: String? = nil
  ) -> Conversation {
    var c = Conversation(
      id: "c", network: reseau, address: "a", title: "t", preview: "p",
      lastMessageAt: Date(), unreadCount: 0, isArchived: false, transportKey: "!r:s",
      isGroup: false)
    c.encryptionAlgorithm = algorithme
    return c
  }

  func testUnSalonNatifChiffreMontreLeCadenasPlein() {
    let etat = conversation(.selfNote, algorithme: "m.megolm.v1.aes-sha2").confidentialite
    XCTAssertEqual(etat.libelleFR, "Chiffré")
    XCTAssertEqual(etat.symbole, "lock.fill")
    XCTAssertTrue(etat.phraseFR.contains("Seuls les participants"))
  }

  func testUnSalonNatifEnClairLeDit() {
    let etat = conversation(.selfNote).confidentialite
    XCTAssertEqual(etat.libelleFR, "En clair")
    XCTAssertNotEqual(etat.symbole, "lock.fill")
  }

  /// Le cas qui compte : l'installeur pose les portails **chiffrés** depuis la
  /// phase 4. Un client naïf y mettrait un cadenas plein ; ce serait faux.
  func testUnPortailChiffreNeMontreJamaisLeCadenasPlein() {
    for reseau in [MessageNetwork.whatsapp, .signal, .instagram, .messenger] {
      let etat = conversation(reseau, algorithme: "m.megolm.v1.aes-sha2").confidentialite
      XCTAssertEqual(
        etat.libelleFR, "Chiffré par le pont",
        "\(reseau) : le libellé doit nommer le pont, pas le bout en bout")
      XCTAssertNotEqual(
        etat.symbole, "lock.fill",
        "\(reseau) : le cadenas plein est réservé au chiffrement de bout en bout")
      XCTAssertTrue(
        etat.phraseFR.contains("pont"),
        "\(reseau) : la phrase doit dire qui lit — \(etat.phraseFR)")
    }
  }

  func testUnPortailEnClairDitEnClair() {
    XCTAssertEqual(conversation(.whatsapp).confidentialite.libelleFR, "En clair")
  }

  /// Un algorithme qu'on ne sait pas déchiffrer n'est pas une garantie.
  func testUnAlgorithmeInconnuNePasseNiPourChiffreNiPourSur() {
    let etat = conversation(.selfNote, algorithme: "x.inconnu").confidentialite
    XCTAssertEqual(etat.libelleFR, "En clair")
  }
}

/// Le fait doit d'abord traverser le `/sync` : sans ça, l'écran affiche « en
/// clair » sur un salon chiffré, ce qui est le mensonge inverse.
final class MatrixEncryptionStateTests: XCTestCase {

  func testLeParseurReleveMRoomEncryption() {
    let parser = MatrixSyncParser(selfUserID: "@moi:s")
    var modele = MatrixRoomModel(roomID: "!r:s")
    parser.applyState(
      [
        MatrixEvent(
          type: "m.room.encryption", stateKey: "",
          content: .object(["algorithm": .string("m.megolm.v1.aes-sha2")]))
      ], roomID: "!r:s", to: &modele)
    XCTAssertEqual(modele.encryptionAlgorithm, "m.megolm.v1.aes-sha2")
  }

  /// Le champ survit à un redémarrage : sinon la fiche dirait « en clair »
  /// jusqu'au prochain event d'état, c'est-à-dire peut-être jamais.
  func testLAlgorithmeSurvitAuStockage() {
    var modele = MatrixRoomModel(roomID: "!r:s")
    modele.network = .whatsapp
    modele.encryptionAlgorithm = "m.megolm.v1.aes-sha2"
    let stocke = StoredRoom(model: modele, selfUserID: "@moi:s")
    XCTAssertEqual(stocke.state.encryptionAlgorithm, "m.megolm.v1.aes-sha2")
    XCTAssertEqual(stocke.model().encryptionAlgorithm, "m.megolm.v1.aes-sha2")
  }
}
