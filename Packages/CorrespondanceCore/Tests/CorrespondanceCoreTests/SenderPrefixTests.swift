import XCTest
@testable import CorrespondanceCore

/// Le nom de l'auteur ne vit plus dans le corps du message — sauf dans l'aperçu
/// de la liste, et dans les caches écrits avant ce changement.
final class SenderPrefixTests: XCTestCase {
  // MARK: - Aperçu de la liste

  func testLApercuDUnGroupeAnnonceQuiParle() {
    XCTAssertEqual(
      SenderPrefix.previewLine("à demain", senderName: "Vince", isGroup: true),
      "Vince: à demain"
    )
  }

  func testLApercuDUnTeteATeteNeRepeteJamaisLeNom() {
    XCTAssertEqual(
      SenderPrefix.previewLine("à demain", senderName: "Vince", isGroup: false),
      "à demain"
    )
  }

  func testUnAuteurInconnuNeProduitPasDApercuOrphelin() {
    XCTAssertEqual(
      SenderPrefix.previewLine("à demain", senderName: nil, isGroup: true),
      "à demain"
    )
  }

  func testUnCorpsVideResteVideDansLApercu() {
    XCTAssertEqual(SenderPrefix.previewLine("", senderName: "Vince", isGroup: true), "")
  }

  // MARK: - Relecture des anciens caches

  func testUnAncienCorpsPrefixeSeSepareEnNomEtTexte() {
    let split = SenderPrefix.splittingLegacySenderPrefix("Vince: à rajouter dans la liste")
    XCTAssertEqual(split?.senderName, "Vince")
    XCTAssertEqual(split?.body, "à rajouter dans la liste")
  }

  func testUnNomAvecEmojiEtEspacesSeSepareAussi() {
    let split = SenderPrefix.splittingLegacySenderPrefix("Romain ⚜️: Tout est propre ?")
    XCTAssertEqual(split?.senderName, "Romain ⚜️")
    XCTAssertEqual(split?.body, "Tout est propre ?")
  }

  func testUneURLNEstPasCoupeeEnDeux() {
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("https://bastiat.org/fr/l_etat.html"))
  }

  func testUnCorpsPrefixePuisSuiviDUneURLGardeSonURLEntiere() {
    let split = SenderPrefix.splittingLegacySenderPrefix("Vince: voir https://bastiat.org/")
    XCTAssertEqual(split?.senderName, "Vince")
    XCTAssertEqual(split?.body, "voir https://bastiat.org/")
  }

  func testUnTexteSansDeuxPointsNEstPasTouche() {
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("à rajouter dans la liste"))
  }

  func testUnDeuxPointsSansEspaceNEstPasUnPrefixe() {
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("Vince:à demain"))
  }

  func testUneLonguePhraseAvantLeDeuxPointsNEstPasUnNom() {
    let long = String(repeating: "a", count: 41)
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("\(long): suite"))
  }

  func testUnPrefixeSansCorpsNEstPasUnPrefixe() {
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("Vince: "))
  }

  func testUnNomSurPlusieursLignesNEstPasUnNom() {
    XCTAssertNil(SenderPrefix.splittingLegacySenderPrefix("Vince\nRomain: salut"))
  }
}

/// L'aperçu d'un fil vient du dernier message : c'est là que le nom doit
/// réapparaître, maintenant qu'il a quitté le corps de la bulle.
final class ChatMessageListPreviewTests: XCTestCase {
  private func message(text: String, senderName: String?, fromMe: Bool = false) -> ChatMessage {
    ChatMessage(
      id: "1",
      conversationID: "signal-group:abc",
      network: .signal,
      text: text,
      sentAt: Date(timeIntervalSince1970: 0),
      isFromMe: fromMe,
      senderName: senderName
    )
  }

  func testLApercuDUnGroupeAnnonceQuiParle() {
    XCTAssertEqual(
      message(text: "à demain", senderName: "Vince").listPreview(isGroup: true),
      "Vince: à demain"
    )
  }

  func testLApercuDUnTeteATeteResteNu() {
    XCTAssertEqual(
      message(text: "à demain", senderName: "Vince").listPreview(isGroup: false),
      "à demain"
    )
  }

  func testMesProprersMessagesNeSAnnoncentPasParMonNom() {
    XCTAssertEqual(
      message(text: "j’arrive", senderName: "Moi", fromMe: true).listPreview(isGroup: true),
      "j’arrive"
    )
  }

  func testUnePhotoSansTexteGardeSonEtiquetteEtSonAuteur() {
    var photo = message(text: "", senderName: "Vince")
    photo.attachments = [MessageAttachment(id: "a.jpg", contentType: "image/jpeg")]
    XCTAssertEqual(photo.listPreview(isGroup: true), "Vince: 📷 Photo")
  }
}
