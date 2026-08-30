import XCTest
@testable import CorrespondanceCore

/// Idempotence du `txnId` : rejouer un envoi ne doit pas créer un second message.
final class MatrixTransactionLedgerTests: XCTestCase {
  func testTransactionIDIsStablePerLocalID() {
    var ledger = MatrixTransactionLedger()
    let first = ledger.transactionID(forLocalID: "local-42")
    let second = ledger.transactionID(forLocalID: "local-42")
    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, ledger.transactionID(forLocalID: "local-43"))
  }

  func testUsedTransactionIDIsRememberedOnlyAfterSuccess() {
    var ledger = MatrixTransactionLedger()
    let txn = ledger.transactionID(forLocalID: "local-42")
    // Un échec réseau ne marque rien : le message reste rejouable.
    XCTAssertFalse(ledger.isUsed(txn))
    ledger.markUsed(txn)
    XCTAssertTrue(ledger.isUsed(txn))
    // Le même identifiant local rend le même txnId → l'envoi est court-circuité.
    XCTAssertTrue(ledger.isUsed(ledger.transactionID(forLocalID: "local-42")))
    XCTAssertFalse(ledger.isUsed(ledger.transactionID(forLocalID: "local-43")))
  }

  func testAttachmentTransactionIDsAreDistinctAndDeterministic() {
    var ledger = MatrixTransactionLedger()
    let base = ledger.transactionID(forLocalID: "local-42")
    let zero = ledger.attachmentTransactionID(base: base, index: 0)
    let one = ledger.attachmentTransactionID(base: base, index: 1)
    XCTAssertNotEqual(zero, one)
    XCTAssertNotEqual(zero, base)
    XCTAssertEqual(zero, ledger.attachmentTransactionID(base: base, index: 0))
  }

  func testResetClearsEverything() {
    var ledger = MatrixTransactionLedger()
    let txn = ledger.transactionID(forLocalID: "local-42")
    ledger.markUsed(txn)
    ledger.reset()
    XCTAssertFalse(ledger.isUsed(txn))
  }
}

/// Les clés Matrix contiennent des points (`m.relates_to`) : la résolution de chemin
/// doit les retrouver, sinon les éditions repassent pour des messages neufs.
final class MatrixJSONPathTests: XCTestCase {
  private func decode(_ json: String) throws -> MatrixJSON {
    try JSONDecoder().decode(MatrixJSON.self, from: Data(json.utf8))
  }

  func testDottedKeysAreResolved() throws {
    let json = try decode(#"{"m.relates_to":{"rel_type":"m.replace","event_id":"$a"},"msgtype":"m.text"}"#)
    XCTAssertEqual(json.string(at: "m.relates_to.rel_type"), "m.replace")
    XCTAssertEqual(json.string(at: "m.relates_to.event_id"), "$a")
    XCTAssertEqual(json.string(at: "msgtype"), "m.text")
    XCTAssertNil(json.string(at: "m.relates_to.absent"))
  }

  func testNestedKeysStillResolve() throws {
    let json = try decode(#"{"protocol":{"id":"whatsapp"},"channel":{"id":"33612345678@s.whatsapp.net"}}"#)
    XCTAssertEqual(json.string(at: "protocol.id"), "whatsapp")
    XCTAssertEqual(json.string(at: "channel.id"), "33612345678@s.whatsapp.net")
  }

  func testEmptyStringsAreTreatedAsAbsent() throws {
    let json = try decode(#"{"name":"   "}"#)
    XCTAssertNil(json.string(at: "name"))
  }
}

/// Réponses réelles de `@whatsappbot` (mautrix-whatsapp v26.08).
final class WhatsAppBotReplyTests: XCTestCase {
  func testPairingCodeIsExtracted() {
    XCTAssertEqual(
      MatrixBridgeService.pairingCode(in: "Input the pairing code L7X2-N4KP in the WhatsApp app"),
      "L7X2-N4KP"
    )
    XCTAssertEqual(
      MatrixBridgeService.pairingCode(in: "Input the pairing code `l7x2-n4kp` in the WhatsApp app"),
      "L7X2-N4KP"
    )
  }

  func testNonPairingRepliesYieldNoCode() {
    XCTAssertNil(MatrixBridgeService.pairingCode(in: "Scan the QR code with the WhatsApp mobile app to log in"))
    XCTAssertNil(MatrixBridgeService.pairingCode(in: "Login cancelled."))
    XCTAssertNil(MatrixBridgeService.pairingCode(in: "Input the pairing code soon"))
  }
}
