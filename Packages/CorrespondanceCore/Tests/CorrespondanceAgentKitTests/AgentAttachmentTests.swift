import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceAgentKit

/// Une photo envoyée à cc doit le réveiller, et le fichier doit arriver sur le
/// disque du tour. Avant, le filtre des msgtypes l'écartait avant tout le
/// reste : pas de réponse, pas d'erreur, rien.
final class AgentAttachmentTests: XCTestCase {
  private let moi = "@meffysto:correspondance.local"
  private var config: AgentConfig {
    AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: [moi])
  }

  private func image(
    caption: String?,
    filename: String? = "capture.png",
    url: String? = "mxc://relais/abc",
    mime: String = "image/png",
    size: Int? = 12_345,
    msgtype: String = "m.image"
  ) -> MatrixEvent {
    var content: [String: MatrixJSON] = [
      "msgtype": .string(msgtype),
      "body": .string(caption ?? filename ?? ""),
      "info": .object(["mimetype": .string(mime), "size": .number(Double(size ?? 0))]),
    ]
    if let filename { content["filename"] = .string(filename) }
    if let url { content["url"] = .string(url) }
    return MatrixEvent(
      type: "m.room.message", eventID: "$photo", sender: moi,
      originServerTS: Date().timeIntervalSince1970 * 1000,
      content: .object(content)
    )
  }

  private func request(_ event: MatrixEvent, requiresTrigger: Bool = true) -> AgentRequest? {
    Trigger.request(
      from: event, roomID: "!r", config: config,
      notBefore: Date().addingTimeInterval(-60), requiresTrigger: requiresTrigger
    )
  }

  // MARK: - Reconnaître

  func testUnePhotoLegendeeAvecLeDeclencheurReveilleLAgent() throws {
    let demande = try XCTUnwrap(request(image(caption: "@cc c'est quoi cette erreur ?")))
    XCTAssertEqual(demande.prompt, "c'est quoi cette erreur ?")
    XCTAssertEqual(demande.attachments.count, 1)
    XCTAssertEqual(demande.attachments.first?.filename, "capture.png")
    XCTAssertEqual(demande.attachments.first?.mimeType, "image/png")
  }

  /// En tête-à-tête, une photo nue est une demande : le geste dit « regarde ».
  func testUnePhotoSansLegendeSuffitEnTeteATete() throws {
    let demande = try XCTUnwrap(request(image(caption: nil), requiresTrigger: false))
    XCTAssertEqual(demande.prompt, "")
    XCTAssertEqual(demande.attachments.count, 1)
  }

  /// Ailleurs, il faut la nommer — sinon toute photo d'un salon réveillerait
  /// l'agent.
  func testUnePhotoSansLegendeNeDeclenchePasAilleurs() {
    XCTAssertNil(request(image(caption: nil)))
  }

  /// Le nom du fichier recopié dans `body` par un pont n'est pas une légende.
  func testLeNomDuFichierRecopieNestPasUneLegende() {
    XCTAssertNil(request(image(caption: "capture.png")))
  }

  func testUnMediaSansURLNeDeclenchePas() {
    XCTAssertNil(request(image(caption: "@cc regarde", url: nil)))
  }

  /// Une pièce chiffrée existe sans être lisible : on la porte quand même, pour
  /// pouvoir le dire au moteur plutôt que de l'ignorer.
  func testUnePieceChiffreeEstPorteeMaisMarquee() throws {
    var content: [String: MatrixJSON] = [
      "msgtype": .string("m.image"),
      "body": .string("@cc regarde"),
      "filename": .string("secret.png"),
      "file": .object(["url": .string("mxc://relais/chiffre")]),
    ]
    content["info"] = .object(["mimetype": .string("image/png")])
    let event = MatrixEvent(
      type: "m.room.message", eventID: "$c", sender: moi,
      originServerTS: Date().timeIntervalSince1970 * 1000, content: .object(content)
    )
    let piece = try XCTUnwrap(request(event)?.attachments.first)
    XCTAssertTrue(piece.isEncrypted)
    XCTAssertNil(piece.mxc)
  }

  /// Un nom venu du réseau ne touche pas le disque tel quel.
  func testUnNomDeFichierNeRemontePasLArborescence() {
    // Seul le dernier segment survit, et il ne peut plus désigner un dossier.
    XCTAssertEqual(AgentAttachment.sanitize("../../.ssh/authorized_keys"), "authorized_keys")
    XCTAssertEqual(AgentAttachment.sanitize(".."), "piece-jointe")
    XCTAssertEqual(AgentAttachment.sanitize("photo été.png"), "photo-été.png")
    XCTAssertEqual(AgentAttachment.sanitize("/"), "piece-jointe")
  }

  // MARK: - Poser sur le disque

  func testLeFichierArriveDansLeDossierDuTourEtLePromptLeNomme() async throws {
    let cwd = FileManager.default.temporaryDirectory
      .appending(path: "tour-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let piece = AgentAttachment(mxc: "mxc://relais/abc", filename: "capture.png", mimeType: "image/png", size: 4)
    let lignes = await AgentAttachmentDrop.drop(
      [piece], eventID: "$photo", cwd: cwd.path(),
      download: { _ in Data([0x89, 0x50, 0x4E, 0x47]) }
    )
    let attendu = AgentAttachmentDrop.directory(cwd: cwd.path(), eventID: "$photo")
      .appending(path: "capture.png")
    XCTAssertEqual(lignes, ["- \(attendu.path()) (image/png)"])
    XCTAssertEqual(try Data(contentsOf: attendu).count, 4)
    XCTAssertTrue(AgentAttachmentDrop.promptSection(lignes).contains(attendu.path()))
  }

  /// Ce qui ne peut pas être lu se dit dans le prompt. Un moteur qui ignore une
  /// photo qu'on lui montre répond à côté sans que personne ne sache pourquoi.
  func testCeQuOnNePeutPasLireEstDitAuMoteur() async {
    let cwd = FileManager.default.temporaryDirectory.path()
    let chiffree = AgentAttachment(mxc: nil, filename: "secret.png", mimeType: "image/png")
    let enorme = AgentAttachment(mxc: "mxc://relais/gros", filename: "film.mp4",
                                 mimeType: "video/mp4", size: 200 * 1024 * 1024)
    let cassee = AgentAttachment(mxc: "mxc://relais/ko", filename: "x.pdf", mimeType: "application/pdf", size: 10)

    let lignes = await AgentAttachmentDrop.drop(
      [chiffree, enorme, cassee], eventID: "$e", cwd: cwd,
      download: { _ in throw AgentBackendError.binaryNotFound }
    )
    XCTAssertEqual(lignes.count, 3)
    XCTAssertTrue(lignes[0].contains("chiffrée"))
    XCTAssertTrue(lignes[1].contains("trop lourde"))
    XCTAssertTrue(lignes[2].contains("impossible"))
    XCTAssertTrue(AgentAttachmentDrop.promptSection([]).isEmpty)
  }

  /// Une photo perdue dans une fusion de demandes serait invisible : le texte
  /// partirait sans elle.
  func testLaFusionGardeLesPiecesJointes() throws {
    let base = Date()
    let avec = AgentRequest(
      roomID: "!r", eventID: "$1", sender: moi, prompt: "", sentAt: base,
      attachments: [AgentAttachment(mxc: "mxc://relais/a", filename: "a.png", mimeType: "image/png")]
    )
    let texte = AgentRequest(roomID: "!r", eventID: "$2", sender: moi, prompt: "et ça ?", sentAt: base.addingTimeInterval(1))
    let lot = try XCTUnwrap(RequestBatch.merge([avec, texte]))
    XCTAssertEqual(lot.attachments.count, 1)
    XCTAssertEqual(lot.count, 2)
    XCTAssertTrue(lot.prompt.contains("(une pièce jointe, sans texte)"))
  }
}
