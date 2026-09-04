import XCTest
@testable import CorrespondanceCore

final class MessageArrivalPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testUnMessageEcritALInstantArrive() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-5), now: now))
  }

  func testUnMessageDateDansLeFuturArriveAussi() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(30), now: now))
  }

  func testUnMessageDHierEstDejaVu() {
    XCTAssertFalse(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-86_400), now: now))
  }

  func testLaCoupureEstADeuxMinutes() {
    XCTAssertTrue(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-119), now: now))
    XCTAssertFalse(MessageArrivalPolicy.isNewArrival(sentAt: now.addingTimeInterval(-121), now: now))
  }
}

final class MessageArrivalLedgerTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func message(
    id: String, text: String = "Bonjour", fromMe: Bool = true, sender: String? = nil,
    at offset: TimeInterval = 0, attachments: Int = 0
  ) -> ChatMessage {
    ChatMessage(
      id: id, conversationID: "c1", network: .signal, text: text,
      sentAt: now.addingTimeInterval(offset), isFromMe: fromMe, senderID: sender,
      isPending: id.hasPrefix("local-"),
      attachments: (0..<attachments).map {
        MessageAttachment(id: "a\($0)", contentType: "image/png", filename: "a\($0).png", localPath: nil)
      }
    )
  }

  func testLaCopieDuRelaisNeSeReencrePas() {
    let ledger = MessageArrivalLedger()
    let optimiste = message(id: "local-1")
    XCTAssertFalse(ledger.hasInked(optimiste, now: now))
    ledger.remember(optimiste, now: now)
    XCTAssertTrue(ledger.hasInked(optimiste, now: now))
    // Même texte, même auteur, datée par le serveur trois secondes plus tard.
    XCTAssertTrue(ledger.hasInked(message(id: "$evt1", at: 3), now: now))
  }

  func testUnAutreTexteEstUnAutreMessage() {
    let ledger = MessageArrivalLedger()
    ledger.remember(message(id: "local-1"), now: now)
    XCTAssertFalse(ledger.hasInked(message(id: "local-2", text: "Bonsoir"), now: now))
  }

  func testCeQuiVientDesAutresNAPasDeDouble() {
    let ledger = MessageArrivalLedger()
    ledger.remember(message(id: "$a", fromMe: false, sender: "@a"), now: now)
    XCTAssertTrue(ledger.hasInked(message(id: "$a", fromMe: false, sender: "@a"), now: now))
    // Un second « Bonjour » de la même personne est un second message.
    XCTAssertFalse(ledger.hasInked(message(id: "$b", fromMe: false, sender: "@a"), now: now))
    XCTAssertFalse(ledger.hasInked(message(id: "$c", fromMe: true), now: now))
  }

  func testUnePhotoSeReconnaitAuNombreDePiecesJointes() {
    let ledger = MessageArrivalLedger()
    ledger.remember(message(id: "local-1", text: "📷 Photo", attachments: 1), now: now)
    XCTAssertTrue(ledger.hasInked(message(id: "$evt", text: "IMG_0001.png", at: 2, attachments: 1), now: now))
    XCTAssertFalse(ledger.hasInked(message(id: "$evt2", text: "", at: 2, attachments: 2), now: now))
  }

  func testLeRegistreOublieAuBoutDeDeuxMinutes() {
    let ledger = MessageArrivalLedger()
    ledger.remember(message(id: "local-1"), now: now)
    XCTAssertFalse(ledger.hasInked(message(id: "$late", at: 130), now: now.addingTimeInterval(130)))
  }
}
