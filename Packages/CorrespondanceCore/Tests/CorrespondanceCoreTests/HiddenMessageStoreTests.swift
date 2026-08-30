import XCTest
@testable import CorrespondanceCore

/// Une suppression « ici » ne quitte pas la machine : aucun catalogue réseau ne
/// la connaît, c'est donc à la relecture du fil de la réappliquer — comme
/// l'archivage, et pour la même raison.
final class HiddenMessageStoreTests: XCTestCase {
  private func message(_ id: String) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "whatsapp:!salon",
      network: .whatsapp,
      text: "Salut",
      sentAt: Date(timeIntervalSince1970: 1_756_400_000),
      isFromMe: false
    )
  }

  func testHiddenMessagesLeaveTheThread() {
    let thread = [message("a"), message("b"), message("c")]
    let visible = HiddenMessageStore.visible(thread, hiddenIDs: ["b"])
    XCTAssertEqual(visible.map(\.id), ["a", "c"])
  }

  /// Le cas courant — rien de supprimé : le fil passe sans être recopié en vain.
  func testEmptySetKeepsEverything() {
    let thread = [message("a"), message("b")]
    XCTAssertEqual(HiddenMessageStore.visible(thread, hiddenIDs: []).map(\.id), ["a", "b"])
  }

  /// Un identifiant qui ne correspond à rien (message déjà rédigé côté réseau,
  /// fil d'un autre réseau) ne retire personne.
  func testUnknownIDsAreHarmless() {
    let thread = [message("a")]
    XCTAssertEqual(HiddenMessageStore.visible(thread, hiddenIDs: ["z"]).map(\.id), ["a"])
  }

  /// Aller-retour disque : ce qu'on supprime aujourd'hui doit l'être encore demain.
  func testRoundTripThroughDisk() {
    let previous = HiddenMessageStore.load()
    defer { HiddenMessageStore.save(previous) }
    HiddenMessageStore.save(["imessage-msg-1", "$event:serveur"])
    XCTAssertEqual(HiddenMessageStore.load(), ["imessage-msg-1", "$event:serveur"])
  }
}
