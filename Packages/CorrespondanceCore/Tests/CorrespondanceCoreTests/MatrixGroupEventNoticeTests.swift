import XCTest

@testable import CorrespondanceCore

/// Ce que WhatsApp et Signal disent dans le fil d'un groupe, et qu'on ne
/// disait pas : « X a rejoint le groupe », « Y a ajouté X », « Z a renommé le
/// groupe ». Les fantômes de pont étaient tous tus — à la création du portail
/// ils arrivent en bloc, mais dans un groupe qui vit, c'est bien quelqu'un.
final class MatrixGroupEventNoticeTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!groupe:correspondance.local"
  private let alice = "@whatsapp_33600000001:correspondance.local"
  private let bob = "@whatsapp_33600000002:correspondance.local"
  private let carol = "@whatsapp_33600000003:correspondance.local"

  private func member(_ user: String, membership: String, id: String, sender: String? = nil, name: String, at: Double) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.member", eventID: id, sender: sender ?? user, stateKey: user, originServerTS: at,
      content: .object(["membership": .string(membership), "displayname": .string(name)])
    )
  }

  private func message(_ id: String, sender: String, body: String, at: Double) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.message", eventID: id, sender: sender, stateKey: nil, originServerTS: at,
      content: .object(["msgtype": .string("m.text"), "body": .string(body)])
    )
  }

  private func name(_ value: String, id: String, sender: String, at: Double) -> MatrixEvent {
    MatrixEvent(type: "m.room.name", eventID: id, sender: sender, stateKey: "", originServerTS: at, content: .object(["name": .string(value)]))
  }

  /// Un groupe WhatsApp déjà nommé, avec deux membres et un message.
  private func livingGroup() -> (MatrixSyncParser, MatrixRoomModel) {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: roomID)
    model.bridgeRoomType = "group"
    model.network = .whatsapp
    _ = parser.applyMessages([
      name("Copro", id: "$n0", sender: alice, at: 1_000),
      member(alice, membership: "join", id: "$a", name: "Alice", at: 1_001),
      member(bob, membership: "join", id: "$b", name: "Bob", at: 1_002),
      message("$m1", sender: alice, body: "Bonjour", at: 2_000),
    ], roomID: roomID, to: &model)
    return (parser, model)
  }

  private func systemLines(_ model: MatrixRoomModel) -> [String] {
    model.sortedMessages.compactMap(\.systemEventText)
  }

  func testLaCreationDuPortailNAnnonceRien() {
    let (_, model) = livingGroup()
    XCTAssertEqual(systemLines(model), [])
  }

  func testUnFantomeQuiRejointUnGroupeVivantSeDit() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([member(carol, membership: "join", id: "$c", name: "Carol", at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Carol a rejoint le groupe"])
  }

  func testAjouteParQuelquUnDAutre() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([member(carol, membership: "join", id: "$c", sender: alice, name: "Carol", at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Alice a ajouté Carol"])
  }

  func testAjouteParMoi() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([member(carol, membership: "join", id: "$c", sender: selfUserID, name: "Carol", at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Vous avez ajouté Carol"])
  }

  func testUnDepartSeDit() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([member(bob, membership: "leave", id: "$l", name: "Bob", at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Bob a quitté le groupe"])
    _ = parser.applyMessages([member(alice, membership: "leave", id: "$l2", sender: selfUserID, name: "Alice", at: 3_100)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Bob a quitté le groupe", "Vous avez retiré Alice"])
  }

  func testUnChangementDeNomOuDePhotoNAnnonceRien() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([member(bob, membership: "join", id: "$b2", name: "Robert", at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), [])
    XCTAssertEqual(model.members[bob]?.displayName, "Robert")
  }

  func testLeRenommageSeDit() {
    var (parser, model) = livingGroup()
    _ = parser.applyMessages([name("Copro · Rue des Lilas", id: "$n1", sender: bob, at: 3_000)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model), ["Bob a renommé le groupe « Copro · Rue des Lilas »"])
    XCTAssertEqual(model.explicitName, "Copro · Rue des Lilas")
    _ = parser.applyMessages([name("Voisins", id: "$n2", sender: selfUserID, at: 3_100)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model).last, "Vous avez renommé le groupe « Voisins »")
    // Le même nom rejoué (une relecture d'état) ne dit rien de plus.
    _ = parser.applyMessages([name("Voisins", id: "$n3", sender: bob, at: 3_200)], roomID: roomID, to: &model)
    XCTAssertEqual(systemLines(model).count, 2)
  }

  func testDansUnTeteATeteLesFantomesSeTaisent() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: "!dm:correspondance.local")
    model.bridgeRoomType = "dm"
    model.network = .whatsapp
    _ = parser.applyMessages([
      member(alice, membership: "join", id: "$a", name: "Alice", at: 1_000),
      message("$m1", sender: alice, body: "Salut", at: 2_000),
      member(alice, membership: "leave", id: "$l", name: "Alice", at: 3_000),
      member(alice, membership: "join", id: "$j", name: "Alice", at: 4_000),
    ], roomID: model.roomID, to: &model)
    XCTAssertEqual(systemLines(model), [])
  }
}
