import XCTest
@testable import CorrespondanceCore

/// « ❤️ » se montre nu et grand ; « ok 👍 » reste une phrase dans sa bulle.
/// Toute la difficulté tient dans les emoji COMPOSÉS : un modificateur de
/// teinte, une famille jointe par ZWJ ou un drapeau ne sont qu'une seule
/// grappe, et compter les scalaires les recracherait comme deux ou trois.
final class EmojiTextTests: XCTestCase {

  // MARK: - Le geste

  func testUnSeulEmoji() {
    XCTAssertTrue(EmojiText.isEmojiOnly("❤️"))
    XCTAssertTrue(EmojiText.isEmojiOnly("🎉"))
  }

  func testDeuxEmojiIdentiques() {
    XCTAssertTrue(EmojiText.isEmojiOnly("🎉🎉"))
  }

  func testTroisEmojiPassentEncore() {
    XCTAssertTrue(EmojiText.isEmojiOnly("🎉🎉🎉"))
  }

  /// Un modificateur de teinte : deux scalaires, une seule grappe.
  func testModificateurDeTeinte() {
    XCTAssertTrue(EmojiText.isEmojiOnly("👍🏽"))
  }

  /// Une famille : trois emoji cousus par deux ZWJ. Une grappe, pas trois.
  func testFamilleJointeParZWJ() {
    XCTAssertTrue(EmojiText.isEmojiOnly("👨‍👩‍👧"))
  }

  /// Un drapeau : deux indicateurs régionaux, une grappe.
  func testDrapeau() {
    XCTAssertTrue(EmojiText.isEmojiOnly("🇫🇷"))
    XCTAssertTrue(EmojiText.isEmojiOnly("🇫🇷🇫🇷"))
  }

  /// Les espaces autour — et entre — ne comptent pas : le geste reste un geste.
  func testEspacesIgnores() {
    XCTAssertTrue(EmojiText.isEmojiOnly("  ❤️ \n"))
    XCTAssertTrue(EmojiText.isEmojiOnly("❤️ 🎉"))
  }

  // MARK: - Ce qui reste une phrase

  func testEmojiAccompagneDeTexte() {
    XCTAssertFalse(EmojiText.isEmojiOnly("ok 👍"))
    XCTAssertFalse(EmojiText.isEmojiOnly("👍 ok"))
  }

  func testQuatreEmojiFontUneGuirlande() {
    XCTAssertFalse(EmojiText.isEmojiOnly("🎉🎉🎉🎉"))
    XCTAssertFalse(EmojiText.isEmojiOnly("👍🏽👍🏽👍🏽👍🏽"))
  }

  func testTexteVide() {
    XCTAssertFalse(EmojiText.isEmojiOnly(""))
    XCTAssertFalse(EmojiText.isEmojiOnly("   \n "))
  }

  /// Chiffres et ponctuation portent `Emoji = Yes` chez Unicode pour des
  /// raisons historiques : sans la propriété de PRÉSENTATION, « 3 » passerait
  /// pour un emoji.
  func testChiffresEtPonctuationNeSontPasDesEmoji() {
    XCTAssertFalse(EmojiText.isEmojiOnly("3"))
    XCTAssertFalse(EmojiText.isEmojiOnly("#"))
    XCTAssertFalse(EmojiText.isEmojiOnly("©"))
    XCTAssertFalse(EmojiText.isEmojiOnly("!"))
  }

  // MARK: - Le message, pas seulement son texte

  private func message(
    _ text: String,
    attachments: [MessageAttachment] = [],
    replyTo: QuotedMessage? = nil,
    isRetracted: Bool = false,
    systemEventText: String? = nil
  ) -> ChatMessage {
    ChatMessage(
      id: "m1",
      conversationID: "signal:abc",
      network: .signal,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_700_000_000),
      isFromMe: false,
      attachments: attachments,
      replyTo: replyTo,
      isRetracted: isRetracted,
      systemEventText: systemEventText
    )
  }

  func testMessageDUnSeulEmoji() {
    XCTAssertTrue(message("❤️").isEmojiOnly)
  }

  /// Une photo légendée « 🎉 » reste une photo : la légende ne s'affiche pas
  /// en quarante points par-dessus.
  func testEmojiAvecPhotoNeComptePas() {
    let photo = MessageAttachment(id: "mxc://x/1", contentType: "image/jpeg", filename: "vue.jpg")
    XCTAssertFalse(message("🎉", attachments: [photo]).isEmojiOnly)
  }

  /// Une réponse porte son contexte : la citation a besoin de sa bulle.
  func testEmojiEnReponseCiteeNeComptePas() {
    let quote = QuotedMessage(messageID: "m0", senderName: "Vince", text: "On y va ?")
    XCTAssertFalse(message("👍", replyTo: quote).isEmojiOnly)
  }

  func testMessageAnnuleOuEvenementNeComptePas() {
    XCTAssertFalse(message("❤️", isRetracted: true).isEmojiOnly)
    XCTAssertFalse(message("❤️", systemEventText: "Vince a rejoint le groupe").isEmojiOnly)
  }
}
