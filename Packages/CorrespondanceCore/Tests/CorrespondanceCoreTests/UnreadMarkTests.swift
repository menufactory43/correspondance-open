import XCTest

@testable import CorrespondanceCore

/// La barre des non-lus : où elle se pose, ce qu'elle annonce, quand elle se tait.
final class UnreadMarkTests: XCTestCase {
  private func message(
    _ id: String, fromMe: Bool = false, system: Bool = false, agent: Bool = false
  ) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "fil",
      network: .signal,
      text: system || agent ? "" : "texte \(id)",
      sentAt: Date(),
      isFromMe: fromMe,
      systemEventText: system ? "Nadia a rejoint le groupe" : nil,
      agentProposal: agent ? AgentProposal(agent: "cc", text: "Proposition") : nil
    )
  }

  /// Trois non lus sur cinq messages reçus : la barre se pose devant le
  /// troisième en partant de la fin, et annonce trois.
  func testMarkSitsBeforeTheFirstUnread() {
    let fil = (1...5).map { message("m\($0)") }
    XCTAssertEqual(
      UnreadMark.place(in: fil, unreadCount: 3), UnreadMark.Mark(messageID: "m3", count: 3))
  }

  func testNothingWaitingMeansNoMark() {
    let fil = (1...5).map { message("m\($0)") }
    XCTAssertNil(UnreadMark.place(in: fil, unreadCount: 0))
  }

  /// Mon dernier mot arrête la remontée : rien au-dessus n'attend une lecture.
  /// Le compte du Relais ne le sait pas — c'est à nous de ne pas le croire
  /// sur parole.
  func testMyOwnMessageStopsTheWalkUp() {
    let fil = [
      message("m1"),
      message("m2"),
      message("moi", fromMe: true),
      message("m4"),
      message("m5"),
    ]
    XCTAssertEqual(
      UnreadMark.place(in: fil, unreadCount: 4), UnreadMark.Mark(messageID: "m4", count: 2))
  }

  /// Un fil qui finit par un mot de moi n'a rien qui attende, quoi qu'en dise
  /// le compte. C'est ce qui posait la barre devant ma propre bulle.
  func testNoMarkWhenTheThreadEndsWithMyOwnWord() {
    let fil = [message("m1"), message("m2"), message("moi", fromMe: true)]
    XCTAssertNil(UnreadMark.place(in: fil, unreadCount: 6))
  }

  /// Les événements de groupe et les cartes de l'agent ne sont pas des
  /// messages reçus : ils se sautent sans entrer dans le compte.
  func testSystemEventsAndAgentCardsAreSkipped() {
    let fil = [
      message("m1"),
      message("m2"),
      message("systeme", system: true),
      message("m3"),
      message("agent", agent: true),
    ]
    XCTAssertEqual(
      UnreadMark.place(in: fil, unreadCount: 2), UnreadMark.Mark(messageID: "m2", count: 2))
  }

  /// Le Relais annonce plus que la page n'en porte : la barre dit ce qu'il y a
  /// SOUS elle, pas ce que le serveur a compté. Annoncer douze au-dessus de
  /// deux bulles serait faux.
  func testMarkAnnouncesWhatIsActuallyBelowIt() {
    let fil = [message("m1", fromMe: true), message("m2"), message("m3")]
    XCTAssertEqual(
      UnreadMark.place(in: fil, unreadCount: 12), UnreadMark.Mark(messageID: "m2", count: 2))
  }

  /// Toute la page est neuve : une barre en tête ferait croire à un fil
  /// entièrement non lu.
  func testMarkStaysAwayWhenItWouldSitAtTheveryTop() {
    let fil = (1...3).map { message("m\($0)") }
    XCTAssertNil(UnreadMark.place(in: fil, unreadCount: 3))
    XCTAssertNil(UnreadMark.place(in: fil, unreadCount: 9))
  }
}
