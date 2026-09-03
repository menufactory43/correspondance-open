import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Proposer sans qu'on demande : un tiers écrit, l'agent propose — et
/// seulement là où le salon le dit, seulement à un tiers, jamais en clair.
final class SuggestionTests: XCTestCase {
  let proprietaire = "@meffysto:correspondance.local"
  let tiers = "@whatsapp_336:correspondance.local"
  let now = Date()

  func config(suggest: String? = nil, keywords: [String]? = nil, mode: AgentConfig.RoomMode? = nil) -> AgentConfig {
    var config = AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: [proprietaire])
    config.peers = ["@hermes:correspondance.local"]
    config.rooms["!r"] = AgentConfig.RoomBinding(mode: mode, suggest: suggest, keywords: keywords)
    return config
  }

  func message(de sender: String, _ body: String, msgtype: String = "m.text", extra: [String: MatrixJSON] = [:], at: Date? = nil) -> MatrixEvent {
    var content: [String: MatrixJSON] = ["msgtype": .string(msgtype), "body": .string(body)]
    for (k, v) in extra { content[k] = v }
    return MatrixEvent(type: "m.room.message", eventID: "$e", sender: sender, originServerTS: (at ?? now).timeIntervalSince1970 * 1000, content: .object(content))
  }

  func testUnTiersDeclencheEnAlwaysEtLeFantomeEstLegitime() throws {
    let demande = try XCTUnwrap(Trigger.suggestion(from: message(de: tiers, "tu viens demain ?"), roomID: "!r", config: config(suggest: "always"), notBefore: .distantPast))
    XCTAssertEqual(demande.kind, .suggest)
    XCTAssertEqual(demande.sender, tiers, "le fantôme de pont est l'expéditeur légitime : c'est le tiers")
    XCTAssertTrue(demande.prompt.hasPrefix(Trigger.promptDeSuggestion), "l'instruction est fixe")
    XCTAssertTrue(demande.prompt.contains("« tu viens demain ? »"), "et le message du tiers suit, cité")
  }

  func testNiProprietaireNiBotNiPairNiMessagePilote() {
    let config = config(suggest: "always")
    XCTAssertNil(Trigger.suggestion(from: message(de: proprietaire, "je réponds moi-même"), roomID: "!r", config: config, notBefore: .distantPast), "le propriétaire parle à quelqu'un, pas à l'agent")
    XCTAssertNil(Trigger.suggestion(from: message(de: config.botUserID, "ma propre réponse"), roomID: "!r", config: config, notBefore: .distantPast), "jamais à soi-même")
    XCTAssertNil(Trigger.suggestion(from: message(de: "@hermes:correspondance.local", "salut"), roomID: "!r", config: config, notBefore: .distantPast), "jamais à un autre agent")
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "ok", extra: [AgentWire.pilotedKey: .bool(true)]), roomID: "!r", config: config, notBefore: .distantPast), "jamais à un message piloté")
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "vieux", at: now.addingTimeInterval(-3600)), roomID: "!r", config: config, notBefore: now.addingTimeInterval(-60)), "l'historique n'est pas rejoué")
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "photo.jpg", msgtype: "m.image"), roomID: "!r", config: config, notBefore: .distantPast), "un texte seulement")
  }

  func testOffOuSalonInconnuNeProposeRien() {
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "salut"), roomID: "!r", config: config(), notBefore: .distantPast))
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "salut"), roomID: "!r", config: config(suggest: "off"), notBefore: .distantPast))
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "salut"), roomID: "!autre", config: config(suggest: "always"), notBefore: .distantPast))
  }

  func testLesMotsClesEnMotEntierSansEgardALaCasse() {
    let config = config(suggest: "keywords", keywords: ["devis", "rendez-vous"])
    XCTAssertNotNil(Trigger.suggestion(from: message(de: tiers, "Ton DEVIS est prêt"), roomID: "!r", config: config, notBefore: .distantPast))
    XCTAssertNotNil(Trigger.suggestion(from: message(de: tiers, "on prend rendez-vous ?"), roomID: "!r", config: config, notBefore: .distantPast))
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "la devise du jour"), roomID: "!r", config: config, notBefore: .distantPast), "« devise » n'est pas « devis »")
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "bonjour"), roomID: "!r", config: config, notBefore: .distantPast))
    XCTAssertFalse(Trigger.containsKeyword("rien", among: []), "sans mots, rien ne réveille")
  }

  /// Le propriétaire a répondu pendant les trois secondes : la suggestion
  /// est dépassée. Avant le message du tiers, elle ne l'est pas.
  func testUneSuggestionEstDepasseeSiLeProprietaireARepondu() throws {
    let demande = try XCTUnwrap(Trigger.suggestion(from: message(de: tiers, "tu viens ?"), roomID: "!r", config: config(suggest: "always"), notBefore: .distantPast))
    XCTAssertFalse(Trigger.suggestionDepassee(demande, derniereActiviteProprietaire: nil))
    XCTAssertFalse(Trigger.suggestionDepassee(demande, derniereActiviteProprietaire: now.addingTimeInterval(-10)), "il avait écrit avant : ça ne compte pas")
    XCTAssertTrue(Trigger.suggestionDepassee(demande, derniereActiviteProprietaire: now.addingTimeInterval(1)), "il a répondu depuis : on se tait")
  }

  func testLaPropositionPorteSonGenre() {
    let brouillon = AgentEvents.proposal(text: "ok", agent: "cc", inReplyTo: "$e")
    XCTAssertEqual(brouillon.string(at: AgentWire.ProposalKey.kind), AgentWire.ProposalKind.reply, "le défaut : un brouillon demandé")
    XCTAssertNil(brouillon.string(at: AgentWire.ProposalKey.reason))
    let suggestion = AgentEvents.proposal(text: "ok", agent: "cc", inReplyTo: "$e", kind: AgentWire.ProposalKind.suggest)
    XCTAssertEqual(suggestion.string(at: AgentWire.ProposalKey.kind), "suggest")
    XCTAssertEqual(suggestion.string(at: "m.relates_to.m.in_reply_to.event_id"), "$e")
  }
}
