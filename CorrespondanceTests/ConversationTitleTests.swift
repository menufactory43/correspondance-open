import XCTest
@testable import Correspondance

/// `hasPlaceholderTitle` sur les titres produits par le bridge WhatsApp :
/// tout ce qui est technique doit pouvoir être remplacé par un nom de contact.
final class ConversationTitleTests: XCTestCase {
  private func whatsAppConversation(title: String, address: String = "!salon:correspondance.local") -> Conversation {
    Conversation(
      id: "whatsapp:!salon:correspondance.local",
      network: .whatsapp,
      address: address,
      title: title,
      preview: "Écrire sur WhatsApp…",
      lastMessageAt: Date(timeIntervalSince1970: 0),
      unreadCount: 0,
      isArchived: false,
      transportKey: "!salon:correspondance.local",
      isGroup: false
    )
  }

  func testTechnicalWhatsAppTitlesArePlaceholders() {
    for title in [
      "",
      "   ",
      "!salon:correspondance.local",
      "@whatsapp_lid-19876543210:correspondance.local",
      "whatsapp:!salon:correspondance.local",
      "+33 6 12 34 56 78",
      "33612345678",
      "Groupe WhatsApp",
    ] {
      XCTAssertTrue(
        whatsAppConversation(title: title).hasPlaceholderTitle,
        "« \(title) » devrait être considéré comme un titre technique"
      )
    }
  }

  func testHumanWhatsAppTitlesAreKept() {
    for title in ["Alice Martin", "Vacances 2026", "Maman", "Cabinet Durand & fils"] {
      XCTAssertFalse(
        whatsAppConversation(title: title).hasPlaceholderTitle,
        "« \(title) » devrait être considéré comme un vrai nom"
      )
    }
  }

  func testPreferTitleReplacesOnlyPlaceholders() {
    var conversation = whatsAppConversation(title: "!salon:correspondance.local")
    conversation.preferTitle("Alice Martin")
    XCTAssertEqual(conversation.title, "Alice Martin")
    // Un bon nom ne se fait pas écraser…
    conversation.preferTitle("Bob Dupuis")
    XCTAssertEqual(conversation.title, "Alice Martin")
    // …et un titre technique ne s'installe jamais.
    var raw = whatsAppConversation(title: "+33 6 12 34 56 78")
    raw.preferTitle("@whatsapp_lid-19876543210:correspondance.local")
    XCTAssertEqual(raw.title, "+33 6 12 34 56 78")
  }
}
