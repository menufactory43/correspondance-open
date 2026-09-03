import XCTest
@testable import CorrespondanceCore

/// Les trois réactions réservées à cc : reconnues, traduites en ordre, et
/// ajoutées au sélecteur seulement quand un agent est dans le fil.
final class AgentReactionTests: XCTestCase {
  func testLesTroisEmojiSontReconnus() {
    XCTAssertEqual(AgentReaction.reserved("🤖"), .propose)
    XCTAssertEqual(AgentReaction.reserved("📌"), .retiens)
    XCTAssertEqual(AgentReaction.reserved("🌐"), .traduis)
    XCTAssertEqual(AgentReaction.reserved("🌐\u{FE0F}"), .traduis, "la variante avec sélecteur de présentation")
  }

  func testUnEmojiOrdinaireNEstPasUnOrdre() {
    XCTAssertNil(AgentReaction.reserved("👍"))
    XCTAssertNil(AgentReaction.reserved("❤️"))
    XCTAssertNil(AgentReaction.reserved(""))
  }

  func testChaqueReactionAUneInstruction() {
    for reaction in AgentReaction.allCases {
      XCTAssertFalse(reaction.instructionFR.isEmpty)
      XCTAssertFalse(reaction.instructionFR.hasPrefix("@"), "le nom de l'agent est ajouté à l'envoi, pas ici")
    }
    XCTAssertEqual(AgentReaction.propose.instructionFR, "propose une réponse à ce message")
    XCTAssertEqual(AgentReaction.traduis.instructionFR, "traduis ce message en français")
  }

  func testLaPaletteNeMontreLesReserveesQuAvecUnAgent() {
    XCTAssertEqual(QuickReactions.palette(agentPresent: false), QuickReactions.base)
    XCTAssertEqual(QuickReactions.palette(agentPresent: true), QuickReactions.base + ["🤖", "📌", "🌐"])
  }
}
