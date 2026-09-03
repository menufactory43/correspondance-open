import XCTest

@testable import CorrespondanceCore

/// Le partage depuis les autres apps, éprouvé hors extension : l'index que
/// l'app écrit, la boîte où l'extension dépose, et la voie choisie.
final class PartageTests: XCTestCase {
  private var boite: PartageBoite!

  override func setUp() {
    super.setUp()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("partage-tests-\(UUID().uuidString)", isDirectory: true)
    boite = PartageBoite(base: base)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: boite.base)
    super.tearDown()
  }

  private func conversation(
    _ id: String, title: String, network: MessageNetwork, at: TimeInterval,
    archived: Bool = false, group: Bool = false
  ) -> Conversation {
    Conversation(
      id: id, network: network, address: id, title: title, preview: "",
      lastMessageAt: Date(timeIntervalSince1970: at), unreadCount: 0, isArchived: archived,
      transportKey: id, isGroup: group
    )
  }

  // MARK: L'index

  func testIndexRecentsDabordSansLesArchives() {
    let index = Partage.index(conversations: [
      conversation("signal:!a:r", title: "Julie", network: .signal, at: 100),
      conversation("whatsapp:!b:r", title: "Marc", network: .whatsapp, at: 300),
      conversation("imessage:x", title: "Rangée", network: .iMessage, at: 900, archived: true),
    ])
    XCTAssertEqual(index.destinataires.map(\.title), ["Marc", "Julie"])
  }

  func testIndexAllerRetourParLaBoite() throws {
    let index = Partage.index(conversations: [
      conversation("signal:!a:r", title: "Julie", network: .signal, at: 100, group: true)
    ], avatarFile: { _ in "abc.img" })
    try boite.ecrire(index)
    let relu = try XCTUnwrap(boite.lireIndex())
    XCTAssertEqual(relu.destinataires, index.destinataires)
    XCTAssertEqual(relu.destinataires.first?.avatarFile, "abc.img")
    XCTAssertTrue(relu.destinataires.first?.isGroup ?? false)
  }

  func testBoiteVideSansIndex() {
    XCTAssertNil(boite.lireIndex())
    XCTAssertEqual(boite.enAttente(), [])
  }

  // MARK: La recherche

  func testClasserIgnoreAccentsEtCasse() {
    let rows = [
      Partage.Destinataire(id: "1", title: "Éléonore Dupont", network: .signal, lastMessageAt: .now),
      Partage.Destinataire(id: "2", title: "Marc", network: .whatsapp, lastMessageAt: .now),
    ]
    XCTAssertEqual(Partage.classer(rows, requete: "eleo").map(\.id), ["1"])
    XCTAssertEqual(Partage.classer(rows, requete: "DUPONT eleo").map(\.id), ["1"])
    XCTAssertEqual(Partage.classer(rows, requete: "whatsapp").map(\.id), ["2"])
    XCTAssertEqual(Partage.classer(rows, requete: "  ").map(\.id), ["1", "2"])
  }

  // MARK: La voie

  func testVoieDirecteSurIPhoneQuandLeFilAUnSalon() {
    let signal = Partage.Destinataire(id: "signal:!a:r", title: "J", network: .signal, lastMessageAt: .now)
    XCTAssertEqual(
      Partage.voie(pour: signal, sessionDisponible: true, plateforme: .iOS),
      .directe(roomID: "!a:r")
    )
    XCTAssertEqual(Partage.voie(pour: signal, sessionDisponible: false, plateforme: .iOS), .parApp)
    XCTAssertEqual(Partage.voie(pour: signal, sessionDisponible: true, plateforme: .macOS), .parApp)
  }

  func testVoieParAppPourUnSalonChiffre() {
    let chiffre = Partage.Destinataire(
      id: "signal:!a:r", title: "J", network: .signal, lastMessageAt: .now, isEncrypted: true)
    XCTAssertEqual(Partage.voie(pour: chiffre, sessionDisponible: true, plateforme: .iOS), .parApp)
  }

  func testVoieParAppPourIMessage() {
    let imsg = Partage.Destinataire(id: "imessage:chat123", title: "J", network: .iMessage, lastMessageAt: .now)
    XCTAssertNil(imsg.roomID)
    XCTAssertEqual(Partage.voie(pour: imsg, sessionDisponible: true, plateforme: .iOS), .parApp)
  }

  // MARK: Le contenu

  func testMessageMotPuisLien() {
    let contenu = Partage.Contenu(texte: "https://exemple.fr/a")
    XCTAssertEqual(contenu.message(avecMot: " Regarde "), "Regarde\nhttps://exemple.fr/a")
    XCTAssertEqual(contenu.message(avecMot: ""), "https://exemple.fr/a")
    XCTAssertTrue(Partage.Contenu().estVide)
    XCTAssertFalse(Partage.Contenu(fichiers: [URL(fileURLWithPath: "/x.jpg")]).estVide)
  }

  // MARK: Les dépôts

  private func fichierTemporaire(_ nom: String, _ octets: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("partage-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(nom)
    try Data(octets.utf8).write(to: url)
    return url
  }

  func testDeposerPuisRetirer() throws {
    let a = try fichierTemporaire("IMG_1.jpg", "aaa")
    let b = try fichierTemporaire("IMG_1.jpg", "bbb")
    let depot = try boite.deposer(conversationID: "signal:!a:r", network: .signal, text: "salut", fichiers: [a, b])
    XCTAssertEqual(depot.fichiers, ["IMG_1.jpg", "IMG_1-2.jpg"])

    let attente = boite.enAttente()
    XCTAssertEqual(attente, [depot])
    let contenus = try boite.fichiers(de: depot).map { try String(contentsOf: $0, encoding: .utf8) }
    XCTAssertEqual(contenus, ["aaa", "bbb"])

    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("partage-dest-\(UUID().uuidString)", isDirectory: true)
    let sortis = try boite.retirer(depot, vers: dest)
    XCTAssertEqual(sortis.map(\.lastPathComponent), ["IMG_1.jpg", "IMG_1-2.jpg"])
    XCTAssertEqual(try String(contentsOf: sortis[1], encoding: .utf8), "bbb")
    XCTAssertEqual(boite.enAttente(), [])
    try? FileManager.default.removeItem(at: dest)
  }

  func testDepotsDuPlusAncienAuPlusRecent() throws {
    let second = try boite.deposer(conversationID: "b", network: .whatsapp, text: "2", fichiers: [])
    let premier = try boite.deposer(conversationID: "a", network: .signal, text: "1", fichiers: [])
    // Même seconde : on force l'ordre par la fiche.
    var ancien = premier
    ancien.createdAt = second.createdAt.addingTimeInterval(-60)
    let fiche = boite.depots.appendingPathComponent(ancien.id).appendingPathComponent("depot.json")
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(ancien).write(to: fiche)
    XCTAssertEqual(boite.enAttente().map(\.text), ["1", "2"])
  }

  // MARK: Les photos

  func testAvatarPoseUneFoisEtBalaye() throws {
    let nom = try XCTUnwrap(boite.poserAvatar(Data("img".utf8), cle: "mxc://r/abc"))
    XCTAssertEqual(boite.poserAvatar(Data("autre".utf8), cle: "mxc://r/abc"), nom)
    XCTAssertEqual(boite.avatar(nom), Data("img".utf8))
    XCTAssertNil(boite.avatar(nil))
    boite.balayerAvatars(gardant: Partage.Index(destinataires: []))
    XCTAssertNil(boite.avatar(nom))
  }
}
