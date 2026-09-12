import XCTest

@testable import CorrespondanceCore

/// La barre des non-lus : où elle se pose, et quand elle se tait.
final class UnreadMarkTests: XCTestCase {
  private func message(_ id: String, fromMe: Bool = false, system: Bool = false) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "fil",
      network: .signal,
      text: system ? "" : "texte \(id)",
      sentAt: Date(),
      isFromMe: fromMe,
      systemEventText: system ? "Nadia a rejoint le groupe" : nil
    )
  }

  /// Trois non lus sur cinq messages : la barre se pose devant le troisième
  /// en partant de la fin.
  func testMarkSitsBeforeTheFirstUnread() {
    let fil = (1...5).map { message("m\($0)") }
    XCTAssertEqual(UnreadMark.firstUnreadID(messages: fil, unreadCount: 3), "m3")
  }

  func testNothingWaitingMeansNoMark() {
    let fil = (1...5).map { message("m\($0)") }
    XCTAssertNil(UnreadMark.firstUnreadID(messages: fil, unreadCount: 0))
  }

  /// L'attente déborde la page chargée : une barre en tête dirait « tout ce
  /// qui suit est neuf » d'un fil entier. On préfère ne rien dire.
  func testMarkStaysAwayWhenUnreadCoversTheWholePage() {
    let fil = (1...3).map { message("m\($0)") }
    XCTAssertNil(UnreadMark.firstUnreadID(messages: fil, unreadCount: 3))
    XCTAssertNil(UnreadMark.firstUnreadID(messages: fil, unreadCount: 9))
  }

  /// Le compte du Relais ne compte que ce qui vient des autres : la barre
  /// saute mes propres bulles pour se poser devant le premier message reçu.
  func testMarkSkipsMyOwnMessagesAndSystemEvents() {
    let fil = [
      message("m1"),
      message("m2"),
      message("m3", fromMe: true),
      message("m4", system: true),
      message("m5"),
    ]
    XCTAssertEqual(UnreadMark.firstUnreadID(messages: fil, unreadCount: 3), "m5")
  }

  /// Rien que de moi dans ce qui attend : aucune barre à poser.
  func testNoMarkWhenOnlyMyMessagesTrail() {
    let fil = [message("m1"), message("m2", fromMe: true), message("m3", fromMe: true)]
    XCTAssertNil(UnreadMark.firstUnreadID(messages: fil, unreadCount: 2))
  }
}
