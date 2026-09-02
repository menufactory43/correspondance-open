import XCTest
import CorrespondanceCore
@testable import Correspondance

/// La bulle qu'on vient d'envoyer survit au rafraîchissement du fil : un
/// `/sync` qui revient pendant l'envoi — l'agent qui se met à « écrire » —
/// ne doit pas l'effacer. Une fois livrée, la copie du Relais la remplace.
@MainActor
final class InFlightBubbleTests: XCTestCase {
  private func message(_ id: String, fromMe: Bool, pending: Bool = false) -> ChatMessage {
    ChatMessage(
      id: id, conversationID: "!salon", network: .signal, text: id,
      sentAt: Date(timeIntervalSince1970: 1_700_000_000), isFromMe: fromMe, isPending: pending
    )
  }

  func testPendingOwnBubbleIsCarriedOver() {
    let current = [message("a", fromMe: false), message("local-1", fromMe: true, pending: true)]
    let fresh = [message("a", fromMe: false), message("b", fromMe: false)]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["a", "b", "local-1"])
  }

  func testDeliveredBubbleYieldsToTheRelayCopy() {
    let current = [message("local-1", fromMe: true, pending: false)]
    let fresh = [message("$event", fromMe: true)]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["$event"])
  }

  func testAlreadyKnownBubbleIsNotDuplicated() {
    let current = [message("local-1", fromMe: true, pending: true)]
    let fresh = [message("local-1", fromMe: true)]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["local-1"])
  }

  // MARK: - L'écho local d'un message déjà parti

  private func echo(_ id: String, text: String, ageSeconds: Double = 5) -> ChatMessage {
    ChatMessage(
      id: id, conversationID: "imessage:1", network: .iMessage, text: text,
      sentAt: Date().addingTimeInterval(-ageSeconds), isFromMe: true
    )
  }

  /// Le cas du bug : Messages écrit dans le WAL, le veilleur relit `chat.db`
  /// avant que la ligne n'y soit, et le message envoyé disparaissait du fil.
  func testSentBubbleSurvivesAReadThatDoesNotSeeItYet() {
    let current = [echo("local-1", text: "Salut")]
    let fresh = [message("a", fromMe: false)]
    XCTAssertEqual(InboxStore.keepingLocalEchoes(fresh, from: current).map(\.id), ["a", "local-1"])
  }

  /// La base a rattrapé son retard : c'est sa ligne qui reste, pas l'écho.
  func testEchoYieldsOnceTheDatabaseShowsTheMessage() {
    let current = [echo("local-1", text: "Salut")]
    let fresh = [
      ChatMessage(
        id: "imessage:42", conversationID: "imessage:1", network: .iMessage,
        text: " Salut ", sentAt: Date(), isFromMe: true
      )
    ]
    XCTAssertEqual(InboxStore.keepingLocalEchoes(fresh, from: current).map(\.id), ["imessage:42"])
  }

  /// Un écho jamais apparié (une pièce jointe, dont le texte ne ressemble à
  /// rien dans la base) finit par être lâché : mieux vaut le perdre que le
  /// figer en doublon éternel.
  func testStaleEchoIsDropped() {
    let current = [echo("local-1", text: "📷 Photo", ageSeconds: 3600)]
    let fresh = [message("a", fromMe: false)]
    XCTAssertEqual(InboxStore.keepingLocalEchoes(fresh, from: current).map(\.id), ["a"])
  }
}
