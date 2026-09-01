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
}
