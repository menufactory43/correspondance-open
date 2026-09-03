import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Le fil donné au moteur : ordonné, attribué, horodaté, encadré comme des
/// données — et jamais plus long que le budget.
final class ContexteDuFilTests: XCTestCase {
  let moi = "@cc:correspondance.local"
  let noms = ["@meffysto:correspondance.local": "meffysto", "@whatsapp_336:correspondance.local": "Camille"]
  // Un jeudi, 19:21 UTC : 2026-09-03T19:21:00Z.
  let jeudi = Date(timeIntervalSince1970: 1_788_463_260)

  func message(_ id: String, de sender: String, _ body: String, at date: Date, msgtype: String = "m.text", extra: [String: MatrixJSON] = [:]) -> MatrixEvent {
    var content: [String: MatrixJSON] = ["msgtype": .string(msgtype), "body": .string(body)]
    for (k, v) in extra { content[k] = v }
    return MatrixEvent(type: "m.room.message", eventID: id, sender: sender, originServerTS: date.timeIntervalSince1970 * 1000, content: .object(content))
  }

  func testOrdreChronologiqueNomsEtHorodatage() {
    let events = [
      message("$2", de: moi, "je regarde", at: jeudi.addingTimeInterval(60)),
      message("$1", de: "@whatsapp_336:correspondance.local", "le plombier vient demain", at: jeudi),
      message("$3", de: "@inconnu:ailleurs.tld", "ok", at: jeudi.addingTimeInterval(120)),
    ]
    let section = ContexteDuFil.section(events: events, moi: moi, noms: noms, exclure: [], timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertTrue(section.hasPrefix(ContexteDuFil.preambule), "le préambule dit que ce sont des données")
    XCTAssertTrue(section.contains(ContexteDuFil.fermeture))
    let lignes = section.split(separator: "\n").map(String.init)
    let camille = try? XCTUnwrap(lignes.firstIndex { $0.contains("Camille : le plombier vient demain") })
    let cc = try? XCTUnwrap(lignes.firstIndex { $0.contains("cc : je regarde") })
    let inconnu = try? XCTUnwrap(lignes.firstIndex { $0.contains("inconnu : ok") })
    XCTAssertLessThan(camille ?? 99, cc ?? 0, "du plus ancien au plus récent")
    XCTAssertLessThan(cc ?? 99, inconnu ?? 0)
    XCTAssertTrue(lignes[camille ?? 0].contains("19:21]"), "l'heure, entre crochets : \(lignes[camille ?? 0])")
    XCTAssertTrue(lignes[camille ?? 0].lowercased().contains("jeu"), "le jour, en français : \(lignes[camille ?? 0])")
  }

  func testMediasEtChiffres() {
    let events = [
      message("$1", de: "@meffysto:correspondance.local", "IMG_1.jpg", at: jeudi, msgtype: "m.image"),
      message("$2", de: "@meffysto:correspondance.local", "regarde ça", at: jeudi.addingTimeInterval(1), msgtype: "m.image", extra: ["filename": .string("IMG_2.jpg")]),
      message("$3", de: "@meffysto:correspondance.local", "vocal.ogg", at: jeudi.addingTimeInterval(2), msgtype: "m.audio"),
      message("$4", de: "@meffysto:correspondance.local", "devis.pdf", at: jeudi.addingTimeInterval(3), msgtype: "m.file"),
      MatrixEvent(type: "m.room.encrypted", eventID: "$5", sender: "@meffysto:correspondance.local", originServerTS: jeudi.addingTimeInterval(4).timeIntervalSince1970 * 1000, content: .object(["algorithm": .string("m.megolm.v1.aes-sha2")])),
      MatrixEvent(type: "m.reaction", eventID: "$6", sender: "@meffysto:correspondance.local", originServerTS: jeudi.addingTimeInterval(5).timeIntervalSince1970 * 1000, content: .object([:])),
    ]
    let section = ContexteDuFil.section(events: events, moi: moi, noms: noms, exclure: [])
    XCTAssertTrue(section.contains("meffysto : [photo]\n"), "une photo sans légende")
    XCTAssertTrue(section.contains("meffysto : [photo] regarde ça"), "la légende suit (MSC2530)")
    XCTAssertTrue(section.contains("meffysto : [vocal]"))
    XCTAssertTrue(section.contains("meffysto : [fichier devis.pdf]"))
    XCTAssertTrue(section.contains("meffysto : [message chiffré]"))
    XCTAssertFalse(section.contains("m.reaction"), "une réaction ne raconte rien")
  }

  func testExclusionDuLotEtRepliDeCitation() {
    let events = [
      message("$avant", de: "@meffysto:correspondance.local", "> <@x:s> cité\n\nla vraie ligne", at: jeudi),
      message("$lot", de: "@meffysto:correspondance.local", "@cc résume", at: jeudi.addingTimeInterval(1)),
    ]
    let section = ContexteDuFil.section(events: events, moi: moi, noms: noms, exclure: ["$lot"])
    XCTAssertTrue(section.contains("meffysto : la vraie ligne"), "le repli `> …` est retiré")
    XCTAssertFalse(section.contains("@cc résume"), "ce qu'on traite n'est pas répété dans le fil")
  }

  func testTroncatureParLeDebutDansLeBudget() {
    let events = (0..<20).map { i in
      message("$\(i)", de: "@meffysto:correspondance.local", "message numéro \(i) " + String(repeating: "x", count: 50), at: jeudi.addingTimeInterval(Double(i)))
    }
    let section = ContexteDuFil.section(events: events, moi: moi, noms: noms, exclure: [], budgetCaracteres: 400)
    XCTAssertTrue(section.contains("message numéro 19"), "le plus récent reste")
    XCTAssertFalse(section.contains("message numéro 0 "), "le plus ancien saute")
    XCTAssertTrue(section.contains(ContexteDuFil.marqueDeCoupe), "et on dit qu'on a coupé")
    let corps = section.replacingOccurrences(of: ContexteDuFil.preambule, with: "").replacingOccurrences(of: ContexteDuFil.fermeture, with: "")
    XCTAssertLessThanOrEqual(corps.trimmingCharacters(in: .whitespacesAndNewlines).count, 400 + ContexteDuFil.marqueDeCoupe.count + 1)
  }

  func testVideQuandRienARaconter() {
    XCTAssertEqual(ContexteDuFil.section(events: [], moi: moi, noms: [:], exclure: []), "")
    let seulement = [message("$lot", de: "@meffysto:correspondance.local", "@cc", at: jeudi)]
    XCTAssertEqual(ContexteDuFil.section(events: seulement, moi: moi, noms: [:], exclure: ["$lot"]), "")
  }

  func testLesNomsViennentDesMembres() {
    let etats = [
      MatrixEvent(type: "m.room.member", stateKey: "@meffysto:correspondance.local", content: .object(["membership": .string("join"), "displayname": .string("meffysto")])),
      MatrixEvent(type: "m.room.member", stateKey: "@sans:nom", content: .object(["membership": .string("join")])),
      MatrixEvent(type: "m.room.name", stateKey: "", content: .object(["name": .string("Note à soi")])),
    ]
    XCTAssertEqual(ContexteDuFil.noms(dans: etats), ["@meffysto:correspondance.local": "meffysto"])
    XCTAssertEqual(ContexteDuFil.nom(de: "@sans:nom", moi: moi, noms: [:]), "sans", "sinon le localpart")
  }
}
