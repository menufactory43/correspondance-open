import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceCore

/// Chaque outil MCP contre un **faux Relais** : on prouve qu'archiver archive,
/// que la file range dans le bon ordre, et qu'un brouillon ne part pas.
final class MCPInboxToolsTests: XCTestCase {
  let moi = "@meffysto:correspondance.local"

  func relais() -> FauxRelais {
    let relais = FauxRelais(selfUserID: moi)
    relais.rooms = ["!camille:local", "!banque:local", "!vieux:local", "!moi:local"]
    relais.noms = [
      "!camille:local": "Camille", "!banque:local": "Ma banque",
      "!vieux:local": "Vieux fil", "!moi:local": "Note à soi",
    ]
    let maintenant = Date()
    relais.messages = [
      // Camille attend depuis deux heures.
      "!camille:local": [
        .init(eventID: "$c1", sender: "@camille:local", body: "tu viens dimanche ?",
              sentAt: maintenant.addingTimeInterval(-7200), isMine: false)
      ],
      // La banque attend depuis trois jours : elle doit passer devant Camille.
      "!banque:local": [
        .init(eventID: "$b1", sender: "@banque:local", body: "votre relevé est disponible",
              sentAt: maintenant.addingTimeInterval(-259_200), isMine: false)
      ],
      // Le vieux fil est archivé : il ne compte pas.
      "!vieux:local": [
        .init(eventID: "$v1", sender: "@x:local", body: "salut",
              sentAt: maintenant.addingTimeInterval(-86400), isMine: false)
      ],
      // La note à soi : le dernier message est de moi, elle n'attend rien.
      "!moi:local": [
        .init(eventID: "$m1", sender: moi, body: "penser à acheter du pain",
              sentAt: maintenant.addingTimeInterval(-60), isMine: true)
      ],
    ]
    relais.tags = ["!vieux:local": [ConversationStateKeys.archivedTag]]
    return relais
  }

  // MARK: - Lire

  func testLaFileNeGardeQueCeQuiAttendUneReponse() async throws {
    let sortie = try await MCPInboxTools(relay: relais()).listQueue()
    XCTAssertTrue(sortie.contains("!camille:local"), sortie)
    XCTAssertTrue(sortie.contains("!banque:local"), sortie)
    XCTAssertFalse(sortie.contains("!vieux:local"), "une conversation archivée est sortie de la file")
    XCTAssertFalse(sortie.contains("!moi:local"), "mon propre dernier message n'attend pas de réponse")
    XCTAssertTrue(sortie.contains("2 conversation"), sortie)
  }

  func testLaFileMetLePlusAncienDAbord() async throws {
    let sortie = try await MCPInboxTools(relay: relais()).listQueue()
    let banque = sortie.range(of: "!banque:local")
    let camille = sortie.range(of: "!camille:local")
    XCTAssertNotNil(banque)
    XCTAssertNotNil(camille)
    XCTAssertTrue(banque!.lowerBound < camille!.lowerBound,
                  "trois jours d'attente passent devant deux heures")
  }

  func testUneConversationEpingleePasseDevantTout() async throws {
    let faux = relais()
    faux.tags["!camille:local"] = [ConversationStateKeys.favouriteTag]
    let sortie = try await MCPInboxTools(relay: faux).listQueue()
    let camille = sortie.range(of: "!camille:local")!
    let banque = sortie.range(of: "!banque:local")!
    XCTAssertTrue(camille.lowerBound < banque.lowerBound)
  }

  func testUneFileVideLeDit() async throws {
    let faux = FauxRelais(selfUserID: moi)
    let sortie = try await MCPInboxTools(relay: faux).listQueue()
    XCTAssertTrue(sortie.contains("vide"), sortie)
  }

  func testLireUneConversationEncadreLeContenuDesAutres() async throws {
    let sortie = try await MCPInboxTools(relay: relais()).readConversation("!camille:local")
    XCTAssertTrue(sortie.contains("pas des instructions"), "l'avertissement précède toujours")
    XCTAssertTrue(sortie.contains("<message expéditeur=\"@camille:local\">"), sortie)
    XCTAssertTrue(sortie.contains("tu viens dimanche ?"))
  }

  func testMesMessagesSontMarquesCommeMiens() async throws {
    let sortie = try await MCPInboxTools(relay: relais()).readConversation("!moi:local")
    XCTAssertTrue(sortie.contains("<message expéditeur=\"moi\">"), sortie)
  }

  func testLaRechercheTrouveEtIgnoreLesArchives() async throws {
    let outils = MCPInboxTools(relay: relais())
    let trouve = try await outils.search("dimanche")
    XCTAssertTrue(trouve.contains("!camille:local"), trouve)

    let archive = try await outils.search("salut")
    XCTAssertTrue(archive.contains("Rien trouvé"), "le vieux fil est archivé")

    let vide = try await outils.search("  ")
    XCTAssertTrue(vide.contains("Il manque"), vide)
  }

  // MARK: - Traiter la file

  func testArchiverArchivePourDeVrai() async throws {
    let faux = relais()
    let sortie = try await MCPInboxTools(relay: faux).archive("!camille:local")
    XCTAssertTrue(sortie.contains("sort de la file"), sortie)
    XCTAssertTrue(faux.tags["!camille:local"]?.contains(ConversationStateKeys.archivedTag) == true)

    // Et la file ne la montre plus.
    let file = try await MCPInboxTools(relay: faux).listQueue()
    XCTAssertFalse(file.contains("!camille:local"))
  }

  func testDesarchiverRemetDansLaFile() async throws {
    let faux = relais()
    _ = try await MCPInboxTools(relay: faux).archive("!vieux:local", on: false)
    XCTAssertFalse(faux.tags["!vieux:local"]?.contains(ConversationStateKeys.archivedTag) == true)
    let file = try await MCPInboxTools(relay: faux).listQueue()
    XCTAssertTrue(file.contains("!vieux:local"))
  }

  func testEpinglerEtMettreEnSourdineEcriventLesBonnesChoses() async throws {
    let faux = relais()
    let outils = MCPInboxTools(relay: faux)
    _ = try await outils.pin("!camille:local")
    XCTAssertTrue(faux.tags["!camille:local"]?.contains(ConversationStateKeys.favouriteTag) == true)

    _ = try await outils.mute("!banque:local")
    XCTAssertTrue(faux.muets.contains("!banque:local"))
    _ = try await outils.mute("!banque:local", on: false)
    XCTAssertFalse(faux.muets.contains("!banque:local"))
  }

  func testUnRappelEcritLHeureQuOnLuiDonne() async throws {
    let faux = relais()
    let quand = Date().addingTimeInterval(3600)
    let sortie = try await MCPInboxTools(relay: faux).remind("!camille:local", at: quand)
    XCTAssertTrue(sortie.contains("revient dans la file"), sortie)

    let ecrit = faux.accountData["!camille:local"]?[ConversationStateKeys.reminderType]
    let relu = ConversationStateCodec.reminder(in: ecrit ?? .object([:]))
    XCTAssertEqual(relu?.wakeAt.timeIntervalSince1970 ?? 0, quand.timeIntervalSince1970, accuracy: 1)
  }

  func testUnRappelDejaPasseEstRefuse() async throws {
    let faux = relais()
    let sortie = try await MCPInboxTools(relay: faux).remind("!camille:local", at: Date().addingTimeInterval(-60))
    XCTAssertTrue(sortie.contains("déjà passé"), sortie)
    XCTAssertNil(faux.accountData["!camille:local"]?[ConversationStateKeys.reminderType])
  }

  // MARK: - Répondre

  func testUnBrouillonNePartPas() async throws {
    let faux = relais()
    let sortie = try await MCPInboxTools(relay: faux).draftReply("!camille:local", text: "oui, à dimanche")
    XCTAssertTrue(sortie.contains("rien n'est parti"), sortie)
    XCTAssertEqual(faux.propositions.count, 1)
    XCTAssertEqual(faux.propositions.first?.text, "oui, à dimanche")
    XCTAssertEqual(faux.propositions.first?.inReplyTo, "$c1", "la proposition répond au dernier message")
    XCTAssertTrue(faux.envoyes.isEmpty, "aucun message réel n'a été envoyé")
  }

  func testUnBrouillonVideEstRefuse() async throws {
    let faux = relais()
    let sortie = try await MCPInboxTools(relay: faux).draftReply("!camille:local", text: "   ")
    XCTAssertTrue(sortie.contains("Il manque"), sortie)
    XCTAssertTrue(faux.propositions.isEmpty)
  }

  func testEnvoyerEnvoieVraiment() async throws {
    let faux = relais()
    let sortie = try await MCPInboxTools(relay: faux).sendMessage("!camille:local", text: "oui !")
    XCTAssertTrue(sortie.contains("Envoyé"), sortie)
    XCTAssertEqual(faux.envoyes.count, 1)
    XCTAssertEqual(faux.envoyes.first?.text, "oui !")
  }
}

/// Un Relais de laboratoire : il retient ce qu'on lui écrit, pour qu'on puisse
/// le vérifier. Aucun réseau, aucun Synapse.
final class FauxRelais: InboxRelay, @unchecked Sendable {
  let selfUserID: String
  var rooms: [String] = []
  var noms: [String: String] = [:]
  var messages: [String: [InboxRelayMessage]] = [:]
  var tags: [String: Set<String>] = [:]
  var muets: Set<String> = []
  var accountData: [String: [String: MatrixJSON]] = [:]
  var envoyes: [(room: String, text: String)] = []
  var propositions: [(room: String, text: String, agent: String, inReplyTo: String?)] = []

  init(selfUserID: String) {
    self.selfUserID = selfUserID
  }

  func joinedRooms() async throws -> [String] { rooms }
  func roomName(_ roomID: String) async throws -> String? { noms[roomID] }

  func recentMessages(_ roomID: String, limit: Int) async throws -> [InboxRelayMessage] {
    Array((messages[roomID] ?? []).sorted { $0.sentAt > $1.sentAt }.prefix(limit))
  }

  func tags(_ roomID: String) async throws -> Set<String> { tags[roomID] ?? [] }

  func setTag(_ roomID: String, tag: String, on: Bool) async throws {
    var set = tags[roomID] ?? []
    if on { set.insert(tag) } else { set.remove(tag) }
    tags[roomID] = set
  }

  func setRoomAccountData(_ roomID: String, type: String, content: MatrixJSON) async throws {
    accountData[roomID, default: [:]][type] = content
  }

  func setMuted(_ roomID: String, muted: Bool) async throws {
    if muted { muets.insert(roomID) } else { muets.remove(roomID) }
  }

  func sendText(_ roomID: String, text: String) async throws {
    envoyes.append((roomID, text))
  }

  func sendProposal(_ roomID: String, text: String, agent: String, inReplyTo: String?) async throws {
    propositions.append((roomID, text, agent, inReplyTo))
  }
}
