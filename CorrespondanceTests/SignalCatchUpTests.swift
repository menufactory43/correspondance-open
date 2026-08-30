import XCTest
@testable import Correspondance

/// Recompte des non-lus Signal au rattrapage : amorçage, messages de moi,
/// idempotence d'un Actualiser.
final class SignalCatchUpTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_756_400_000)
  private let conversationID = "signal-group:stochastic"

  private func message(
    at offset: TimeInterval,
    fromMe: Bool = false,
    conversationID: String? = nil
  ) -> ChatMessage {
    let id = conversationID ?? self.conversationID
    return ChatMessage(
      id: "signal-\(offset)-\(id)",
      conversationID: id,
      network: .signal,
      text: "Un message",
      sentAt: base.addingTimeInterval(offset),
      isFromMe: fromMe
    )
  }

  func test_marqueurAbsent_neFabriqueAucunNonLu() {
    let messages = [conversationID: [message(at: -300), message(at: -200), message(at: -100)]]
    XCTAssertEqual(
      SignalCatchUp.unreadCounts(messagesByConversation: messages, lastSeenAt: nil),
      [:]
    )
  }

  func test_messagesEntrantsApresMarqueur_comptes() {
    let messages = [conversationID: [
      message(at: -300),
      message(at: 100),
      message(at: 200),
      message(at: 300),
    ]]
    let counts = SignalCatchUp.unreadCounts(
      messagesByConversation: messages,
      lastSeenAt: [conversationID: base]
    )
    XCTAssertEqual(counts[conversationID], 3)
  }

  func test_messagesDeMoi_ignores() {
    let messages = [conversationID: [
      message(at: 100, fromMe: true),
      message(at: 200, fromMe: true),
    ]]
    let counts = SignalCatchUp.unreadCounts(
      messagesByConversation: messages,
      lastSeenAt: [conversationID: base]
    )
    XCTAssertNil(counts[conversationID])
  }

  func test_messageAuMarqueurExact_ignore() {
    let messages = [conversationID: [message(at: 0)]]
    let counts = SignalCatchUp.unreadCounts(
      messagesByConversation: messages,
      lastSeenAt: [conversationID: base]
    )
    XCTAssertNil(counts[conversationID])
  }

  func test_nouvelleConversation_marqueurExistantAilleurs_toutCompte() {
    let autre = "signal-group:cafe-viennois"
    let messages = [
      conversationID: [message(at: 100)],
      autre: [
        message(at: -500, conversationID: autre),
        message(at: -400, conversationID: autre),
      ],
    ]
    let counts = SignalCatchUp.unreadCounts(
      messagesByConversation: messages,
      lastSeenAt: [conversationID: base]
    )
    // Le groupe jamais vu compte tous ses entrants, même antérieurs au marqueur
    // de l'autre fil : les marqueurs sont par conversation.
    XCTAssertEqual(counts[autre], 2)
    XCTAssertEqual(counts[conversationID], 1)
  }

  func test_idempotence_deuxActualiserNeDoublentPasLeBadge() {
    let messages = [conversationID: [message(at: 100), message(at: 200)]]
    let marker = [conversationID: base]
    let premier = SignalCatchUp.unreadCounts(messagesByConversation: messages, lastSeenAt: marker)
    let second = SignalCatchUp.unreadCounts(messagesByConversation: messages, lastSeenAt: marker)
    XCTAssertEqual(premier, second)
    XCTAssertEqual(second[conversationID], 2)
  }

  func test_amorcage_prendLeDernierMessage() {
    let vide = "signal:+33600000000"
    let messages: [String: [ChatMessage]] = [
      conversationID: [message(at: -100), message(at: 300, fromMe: true), message(at: 200)],
      vide: [],
    ]
    let seeds = SignalCatchUp.seededLastSeen(messagesByConversation: messages)
    // Le dernier message compte même s'il est de moi : il vaut lecture du fil.
    XCTAssertEqual(seeds[conversationID], base.addingTimeInterval(300))
    XCTAssertNil(seeds[vide])
  }

  func test_amorcage_puisRecompte_neRendRienDeNonLu() {
    let messages = [conversationID: [message(at: -100), message(at: 200)]]
    let seeds = SignalCatchUp.seededLastSeen(messagesByConversation: messages)
    let counts = SignalCatchUp.unreadCounts(messagesByConversation: messages, lastSeenAt: seeds)
    XCTAssertEqual(counts, [:])
  }

  func test_amorcage_neSertPasARendreDesMessagesDejaLa() {
    // L'amorçage doit rester silencieux : un historique entier ne devient pas
    // un mur de badges le jour où l'on installe la mise à jour.
    let messages = [conversationID: [message(at: -400), message(at: -300), message(at: -200)]]
    let seeds = SignalCatchUp.seededLastSeen(messagesByConversation: messages)
    XCTAssertEqual(seeds.count, 1)
    XCTAssertEqual(
      SignalCatchUp.unreadCounts(messagesByConversation: messages, lastSeenAt: seeds),
      [:]
    )
  }
}
