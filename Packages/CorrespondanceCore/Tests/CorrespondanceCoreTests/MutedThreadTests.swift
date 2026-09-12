import XCTest

@testable import CorrespondanceCore

/// Un fil muet garde son compteur et laisse passer ce qui me concerne.
///
/// Le serveur ne peut pas nous aider ici : la sourdine est une push rule
/// `actions: []`, et `notification_count` compte des NOTIFICATIONS, pas des
/// messages — il vaut donc zéro sur un salon muet, quoi qu'il s'y dise. Tout
/// se dérive de mon propre accusé de lecture, que le `/sync` nous rend.
final class MutedThreadTests: XCTestCase {
  private let moi = "@meffysto:relais"

  private func message(
    _ id: String, at seconds: TimeInterval, fromMe: Bool = false, text: String = "salut",
    system: Bool = false, replyTo: String? = nil
  ) -> ChatMessage {
    var message = ChatMessage(
      id: id, conversationID: "c", network: .signal, text: system ? "" : text,
      sentAt: Date(timeIntervalSince1970: seconds), isFromMe: fromMe,
      systemEventText: system ? "Nadia a rejoint le groupe" : nil
    )
    if let replyTo {
      message.replyTo = QuotedMessage(messageID: replyTo, senderName: "Moi", text: "mon message")
    }
    return message
  }

  private func salon(_ messages: [ChatMessage], marker: String? = nil) -> MatrixRoomModel {
    var model = MatrixRoomModel(roomID: "!g:relais")
    model.bridgeRoomType = "group"
    model.members[moi] = .init(displayName: "Lucas Dupont", membership: "join")
    for message in messages { model.messagesByID[message.id] = message }
    if let marker { model.readMarkerByUser[moi] = marker }
    return model
  }

  // MARK: - Le compteur

  func testCountsWhatArrivedAfterMyReceipt() {
    let model = salon(
      [
        message("$1", at: 10),
        message("$2", at: 20),
        message("$3", at: 30),
        message("$4", at: 40),
      ],
      marker: "$2"
    )
    XCTAssertEqual(model.unreadSinceMyReceipt(selfUserID: moi), 2)
  }

  /// Mes propres messages et les événements de groupe ne sont pas des messages
  /// qui attendent d'être lus.
  func testMyOwnMessagesAndSystemEventsDoNotCount() {
    let model = salon(
      [
        message("$1", at: 10),
        message("$2", at: 20, fromMe: true),
        message("$3", at: 30, system: true),
        message("$4", at: 40),
      ],
      marker: "$1"
    )
    XCTAssertEqual(model.unreadSinceMyReceipt(selfUserID: moi), 1)
  }

  /// Sans accusé de moi dans ce salon, on ne sait rien : annoncer tout
  /// l'historique comme non lu serait pire que se taire.
  func testNoReceiptMeansNoCount() {
    let model = salon([message("$1", at: 10), message("$2", at: 20)])
    XCTAssertEqual(model.unreadSinceMyReceipt(selfUserID: moi), 0)
  }

  func testUpToDateMeansZero() {
    let model = salon([message("$1", at: 10), message("$2", at: 20)], marker: "$2")
    XCTAssertEqual(model.unreadSinceMyReceipt(selfUserID: moi), 0)
  }

  // MARK: - Ce qui me concerne

  func testBeingNamedIsPersonal() {
    let model = salon([message("$1", at: 10, text: "Lucas tu viens ?")])
    XCTAssertTrue(model.lastMessageIsPersonal(selfUserID: moi))
  }

  func testBeingRepliedToIsPersonal() {
    let model = salon([
      message("$mien", at: 10, fromMe: true, text: "je m'en occupe"),
      message("$reponse", at: 20, text: "merci !", replyTo: "$mien"),
    ])
    XCTAssertTrue(model.lastMessageIsPersonal(selfUserID: moi))
  }

  /// Une réponse au message de quelqu'un d'autre ne me concerne pas.
  func testReplyingToSomeoneElseIsNotPersonal() {
    let model = salon([
      message("$sien", at: 10, text: "je m'en occupe"),
      message("$reponse", at: 20, text: "merci !", replyTo: "$sien"),
    ])
    XCTAssertFalse(model.lastMessageIsPersonal(selfUserID: moi))
  }

  func testAnOrdinaryMessageIsNotPersonal() {
    let model = salon([message("$1", at: 10, text: "on se voit demain ?")])
    XCTAssertFalse(model.lastMessageIsPersonal(selfUserID: moi))
  }

  /// Mon propre message ne me concerne pas — je sais déjà ce que j'ai écrit.
  func testMyOwnMessageIsNeverPersonal() {
    let model = salon([message("$1", at: 10, fromMe: true, text: "Lucas, note à moi-même")])
    XCTAssertFalse(model.lastMessageIsPersonal(selfUserID: moi))
  }
}
