import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Répond seul, dans un cadre : le protocole `<hors-cadre>`, les gardes
/// anti-boucle, le plafond, et la marque sur ce qui part au nom du propriétaire.
final class PilotageTests: XCTestCase {
  let proprietaire = "@meffysto:correspondance.local"
  let tiers = "@whatsapp_336:correspondance.local"

  func config(frame: String? = "confirme ou déplace les rendez-vous, rien d'autre") -> AgentConfig {
    var config = AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: [proprietaire])
    config.peers = ["@hermes:correspondance.local"]
    config.rooms["!r"] = AgentConfig.RoomBinding(mode: .pilot, frame: frame)
    return config
  }

  func message(de sender: String, _ body: String, extra: [String: MatrixJSON] = [:]) -> MatrixEvent {
    var content: [String: MatrixJSON] = ["msgtype": .string("m.text"), "body": .string(body)]
    for (k, v) in extra { content[k] = v }
    return MatrixEvent(type: "m.room.message", eventID: "$e", sender: sender, originServerTS: Date().timeIntervalSince1970 * 1000, content: .object(content))
  }

  // MARK: - Le protocole

  func testLeProtocoleHorsCadre() {
    XCTAssertEqual(Pilotage.lire("Oui, 15 h me va."), .reponse("Oui, 15 h me va."))
    XCTAssertEqual(Pilotage.lire("<hors-cadre> il demande un prix"), .horsCadre(raison: "il demande un prix"))
    XCTAssertEqual(Pilotage.lire("<HORS-CADRE> : il demande un prix."), .horsCadre(raison: "il demande un prix."), "la casse et la ponctuation ne comptent pas")
    XCTAssertEqual(Pilotage.lire("`<hors-cadre>` — hors sujet"), .horsCadre(raison: "hors sujet"), "cité comme dans le prompt")
    XCTAssertEqual(Pilotage.lire("<hors-cadre>"), .horsCadre(raison: "le message sort du cadre"), "sans raison, on en met une")
    XCTAssertEqual(Pilotage.lire("   "), .horsCadre(raison: "le moteur n'a rien répondu"), "du vide ne part jamais à un tiers")
    XCTAssertEqual(Pilotage.lire("Je réponds : ce n'est pas <hors-cadre>."), .reponse("Je réponds : ce n'est pas <hors-cadre>."), "seulement en tête")
  }

  // MARK: - Le déclenchement

  func testUnTiersDeclencheUnTourPiloteSansDelaiAvecLeCadre() throws {
    let demande = try XCTUnwrap(Trigger.suggestion(from: message(de: tiers, "on peut décaler à 16 h ?"), roomID: "!r", config: config(), notBefore: .distantPast))
    XCTAssertEqual(demande.kind, .pilot)
    XCTAssertTrue(demande.prompt.contains("« confirme ou déplace les rendez-vous, rien d'autre »"), "le cadre est dans le prompt")
    XCTAssertTrue(demande.prompt.contains("réponds exactement `<hors-cadre>`"))
    XCTAssertTrue(demande.prompt.contains("« on peut décaler à 16 h ? »"), "et le message du tiers, cité")
  }

  func testSansCadreToutEstHorsCadre() throws {
    let demande = try XCTUnwrap(Trigger.suggestion(from: message(de: tiers, "salut"), roomID: "!r", config: config(frame: nil), notBefore: .distantPast))
    XCTAssertTrue(demande.prompt.contains("aucun cadre n'a été donné"))
  }

  /// Jamais de réponse pilotée à un message piloté, à un agent, ou au bot :
  /// c'est la garde anti-boucle, portée par l'event et par la config.
  func testLesGardesAntiBoucle() {
    let config = config()
    XCTAssertNil(Trigger.suggestion(from: message(de: tiers, "ok", extra: [AgentWire.pilotedKey: .bool(true)]), roomID: "!r", config: config, notBefore: .distantPast), "un message piloté")
    XCTAssertNil(Trigger.suggestion(from: message(de: "@hermes:correspondance.local", "ok"), roomID: "!r", config: config, notBefore: .distantPast), "un autre agent")
    XCTAssertNil(Trigger.suggestion(from: message(de: config.botUserID, "ok"), roomID: "!r", config: config, notBefore: .distantPast), "le bot lui-même")
    XCTAssertNil(Trigger.suggestion(from: message(de: proprietaire, "ok"), roomID: "!r", config: config, notBefore: .distantPast), "le propriétaire n'est pas un tiers")
  }

  /// Une mention explicite du propriétaire dans un salon `pilot` reste une
  /// demande ordinaire (`.reply`) : le mode résolu est `pilot`, et c'est
  /// `Agent.reply` qui le traite comme `direct` pour ce genre-là.
  func testUneMentionExpliciteResteUneDemandeOrdinaire() throws {
    let demande = try XCTUnwrap(Trigger.request(from: message(de: proprietaire, "@cc résume"), roomID: "!r", config: config(), notBefore: .distantPast))
    XCTAssertEqual(demande.kind, .reply)
    XCTAssertEqual(AgentMode.resolve(roomMode: .pilot, isPrivateWithOwners: false, accountDataDefault: nil, configuredDefault: .draft), .pilot)
  }

  // MARK: - Le plafond et la marque

  func testLePlafondDesReponsesPiloteesParSalon() {
    var cap = HourlyCap(limit: Pilotage.plafondParHeure)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<Pilotage.plafondParHeure {
      XCTAssertTrue(cap.admit(now: t0.addingTimeInterval(Double(i))), "la \(i + 1)e passe")
    }
    XCTAssertFalse(cap.admit(now: t0.addingTimeInterval(20)), "la onzième attend l'heure suivante")
    XCTAssertTrue(cap.admit(now: t0.addingTimeInterval(3601)))
  }

  func testCeQuiPartEnVotreNomEstMarqueEtLaPassationDitPourquoi() {
    let envoye = AgentEvents.pilotedText("Oui, 15 h me va.", inReplyTo: "$e")
    XCTAssertEqual(envoye.string(at: "msgtype"), "m.text")
    XCTAssertTrue(AgentEvents.isPiloted(envoye), "l'app le marque, et aucun agent n'y répond")
    XCTAssertEqual(envoye.string(at: "m.relates_to.m.in_reply_to.event_id"), "$e")
    XCTAssertFalse(AgentEvents.isPiloted(AgentEvents.replyText("ok", inReplyTo: "$e", delegated: false)))

    let passation = AgentEvents.proposal(text: "", agent: "cc", inReplyTo: "$e", kind: AgentWire.ProposalKind.handover, reason: "il demande un prix")
    XCTAssertEqual(passation.string(at: AgentWire.ProposalKey.kind), "handover")
    XCTAssertEqual(passation.string(at: AgentWire.ProposalKey.reason), "il demande un prix")

    let avis = AgentEvents.notice(agent: "cc", body: "Un message sort du cadre", reason: "handover")
    XCTAssertEqual(avis.string(at: AgentWire.NoticeKey.reason), "handover")
    XCTAssertEqual(avis.string(at: AgentWire.NoticeKey.agent), "cc")
    XCTAssertNil(avis.string(at: AgentWire.NoticeKey.action))
  }
}
