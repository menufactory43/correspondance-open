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

  /// Le cas du bug revenu sur le Mac : le PUT a répondu (`isPending` retombé)
  /// mais le `/sync` qui portera l'événement n'est pas encore passé — celui
  /// déclenché par le brouillon vidé revient sans lui. La bulle ne doit pas
  /// disparaître le temps du `/sync` suivant.
  func testDeliveredBubbleSurvivesASyncThatDoesNotShowItYet() {
    let current = [message("a", fromMe: false), echo("local-1", text: "Salut", network: .signal)]
    let fresh = [message("a", fromMe: false)]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["a", "local-1"])
  }

  /// Et dès que le Relais montre sa copie, c'est elle qui reste.
  func testDeliveredBubbleYieldsOnceTheRelayShowsIt() {
    let current = [echo("local-1", text: "Salut", network: .signal)]
    let fresh = [
      ChatMessage(
        id: "$event", conversationID: "!salon", network: .signal, text: "Salut",
        sentAt: Date(), isFromMe: true
      )
    ]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["$event"])
  }

  /// Une photo envoyée : l'écho dit « 📷 Photo », la copie du Relais porte le
  /// fichier. Même nombre de pièces jointes = même message, pas de doublon.
  func testAttachmentEchoYieldsToTheRelayCopy() {
    let photo = MessageAttachment(id: "p", contentType: "image/jpeg", filename: "p.jpg", localPath: "/tmp/p.jpg")
    var local = echo("local-1", text: "📷 Photo", network: .signal)
    local.attachments = [photo]
    var relayed = ChatMessage(
      id: "$event", conversationID: "!salon", network: .signal, text: "p.jpg",
      sentAt: Date(), isFromMe: true
    )
    relayed.attachments = [photo]
    XCTAssertEqual(InboxStore.keepingInFlight([relayed], from: [local]).map(\.id), ["$event"])
  }

  func testAlreadyKnownBubbleIsNotDuplicated() {
    let current = [message("local-1", fromMe: true, pending: true)]
    let fresh = [message("local-1", fromMe: true)]
    XCTAssertEqual(InboxStore.keepingInFlight(fresh, from: current).map(\.id), ["local-1"])
  }

  // MARK: - L'écho local d'un message déjà parti

  private func echo(
    _ id: String, text: String, ageSeconds: Double = 5, network: MessageNetwork = .iMessage
  ) -> ChatMessage {
    ChatMessage(
      id: id, conversationID: network == .iMessage ? "imessage:1" : "!salon", network: network,
      text: text, sentAt: Date().addingTimeInterval(-ageSeconds), isFromMe: true
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
