import XCTest
@testable import CorrespondanceCore

/// Le découpage du fil en groupes : c'est lui qui décide quand on redate,
/// quand on renomme l'auteur, et quand deux bulles se serrent.
final class MessageGroupingTests: XCTestCase {
  private let origin = Date(timeIntervalSince1970: 1_700_000_000)

  private func message(
    _ id: String,
    _ text: String,
    minutes: Double,
    fromMe: Bool = false,
    sender: String? = "+33600000001",
    name: String? = "Vince"
  ) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "signal-group:abc",
      network: .signal,
      text: text,
      sentAt: origin.addingTimeInterval(minutes * 60),
      isFromMe: fromMe,
      senderID: sender,
      senderName: name
    )
  }

  func testMessagesConsecutifsDuMemeAuteurNeFontQuUnGroupe() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "salut", minutes: 0),
        message("2", "ça va ?", minutes: 1),
        message("3", "t'es là ?", minutes: 2),
      ],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].messages.map(\.id), ["1", "2", "3"])
    XCTAssertEqual(groups[0].senderLabel, "Vince")
  }

  func testUnChangementDAuteurRompLeGroupeSansRedater() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "salut", minutes: 0),
        message("2", "salut", minutes: 1, sender: "+33600000002", name: "Romain"),
      ],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[1].senderLabel, "Romain")
    // Une minute d'écart : la conversation n'a pas changé de moment.
    XCTAssertNil(groups[1].timeSeparator)
  }

  func testUnSilenceDePlusDeCinqMinutesRompLeGroupeEtRedate() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "salut", minutes: 0),
        message("2", "toujours là ?", minutes: 6),
      ],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[1].timeSeparator, origin.addingTimeInterval(6 * 60))
  }

  func testCinqMinutesToutJusteNeRompentPas() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "salut", minutes: 0),
        message("2", "hop", minutes: 5),
      ],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.count, 1)
  }

  func testLePremierGroupePorteToujoursUnHorodatage() {
    let groups = MessageGrouping.groups(
      for: [message("1", "salut", minutes: 0)],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.first?.timeSeparator, origin)
  }

  func testEnTeteATeteAucunNomNEstAnnonce() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "salut", minutes: 0),
        message("2", "salut", minutes: 1, fromMe: true, sender: nil, name: nil),
      ],
      showsSenderNames: false
    )

    XCTAssertEqual(groups.count, 2)
    XCTAssertTrue(groups.allSatisfy { $0.senderLabel == nil })
  }

  func testMesPropresMessagesNeSontJamaisNommes() {
    let groups = MessageGrouping.groups(
      for: [message("1", "ok", minutes: 0, fromMe: true, sender: nil, name: nil)],
      showsSenderNames: true
    )

    XCTAssertNil(groups[0].senderLabel)
    XCTAssertTrue(groups[0].isFromMe)
  }

  func testDeuxMessagesDeMoiEtDeLAutreALaMemeSecondeNeSeMelangentPas() {
    let groups = MessageGrouping.groups(
      for: [
        message("1", "et toi ?", minutes: 0),
        message("2", "moi ça va", minutes: 0, fromMe: true, sender: nil, name: nil),
      ],
      showsSenderNames: true
    )

    XCTAssertEqual(groups.count, 2)
  }

  func testSansNomLIdentifiantReseauFaitOfficeDeLibelle() {
    let groups = MessageGrouping.groups(
      for: [message("1", "salut", minutes: 0, sender: "+33612345678", name: nil)],
      showsSenderNames: true
    )

    XCTAssertEqual(groups[0].senderLabel, "+33612345678")
  }

  func testUnAuteurTotalementInconnuNeProduitPasDeLibelleVide() {
    let groups = MessageGrouping.groups(
      for: [message("1", "salut", minutes: 0, sender: nil, name: nil)],
      showsSenderNames: true
    )

    XCTAssertNil(groups[0].senderLabel)
  }

  func testUnFilVideNeDonneAucunGroupe() {
    XCTAssertTrue(MessageGrouping.groups(for: [], showsSenderNames: true).isEmpty)
  }

  // MARK: - Fil fusionné

  /// Deux bulles d'affilée, mais pas du même réseau : deux groupes.
  private func onNetwork(_ id: String, _ network: MessageNetwork, minutes: Double) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: network == .iMessage ? "imessage:1" : "matrix:1",
      network: network,
      text: "coucou \(id)",
      sentAt: origin.addingTimeInterval(minutes * 60),
      isFromMe: false,
      senderID: "+33612345678",
      senderName: "Vince"
    )
  }

  func testUnChangementDeReseauCasseLeGroupe() {
    let groups = MessageGrouping.groups(
      for: [
        onNetwork("1", .iMessage, minutes: 0),
        onNetwork("2", .iMessage, minutes: 1),
        onNetwork("3", .whatsapp, minutes: 2),
      ],
      showsSenderNames: false
    )

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[0].messages.map(\.id), ["1", "2"])
    XCTAssertEqual(groups[0].network, .iMessage)
    XCTAssertEqual(groups[1].network, .whatsapp)
  }

  func testLOrigineNeSAnnonceQuAuxBascules() {
    let messages = [
      onNetwork("1", .iMessage, minutes: 0),
      onNetwork("2", .iMessage, minutes: 30),
      onNetwork("3", .whatsapp, minutes: 31),
    ]

    let merged = MessageGrouping.groups(for: messages, showsSenderNames: false, showsNetworkOrigin: true)
    XCTAssertEqual(merged.map(\.showsNetworkOrigin), [true, false, true])
    XCTAssertEqual(merged.map(\.networkOrigin), [.iMessage, nil, .whatsapp])
    // Une bascule redate même sans silence : sans ça, l'origine n'aurait nulle
    // part où s'écrire.
    XCTAssertNotNil(merged[2].timeSeparator)

    // Fil ordinaire : personne n'annonce rien.
    let plain = MessageGrouping.groups(for: messages, showsSenderNames: false)
    XCTAssertEqual(plain.map(\.showsNetworkOrigin), [false, false, false])
    XCTAssertNil(plain[2].networkOrigin)
  }

  func testLIdentifiantDuGroupeEstCeluiDeSonPremierMessage() {
    let groups = MessageGrouping.groups(
      for: [message("1", "a", minutes: 0), message("2", "b", minutes: 1)],
      showsSenderNames: true
    )

    XCTAssertEqual(groups[0].id, "1")
  }
}
