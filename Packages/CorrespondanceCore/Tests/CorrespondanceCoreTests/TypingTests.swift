import XCTest
@testable import CorrespondanceCore

/// `m.typing` est une EDU : elle ne revient qu'au changement. Un indicateur qui
/// n'expire pas mentirait jusqu'au prochain message.
final class TypingTests: XCTestCase {
  private let moi = "@meffysto:relais"

  private func model(typing: [String], names: [String: String] = [:]) -> MatrixRoomModel {
    var model = MatrixRoomModel(roomID: "!a:relais")
    for (id, name) in names {
      model.members[id] = .init(displayName: name, membership: "join")
    }
    model.typingUserIDs = Set(typing)
    model.typingUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return model
  }

  private var maintenant: Date { Date(timeIntervalSince1970: 1_800_000_001) }

  func testLeSyncInstalleQuiEcrit() throws {
    let json = """
    {"next_batch":"s1","rooms":{"join":{"!a:relais":{
      "state":{"events":[
        {"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"}}},
        {"type":"m.room.member","state_key":"@whatsapp_lid-1:relais",
         "content":{"membership":"join","displayname":"Alice (WA)"}}]},
      "ephemeral":{"events":[{"type":"m.typing","content":{"user_ids":["@whatsapp_lid-1:relais"]}}]}}}}}
    """
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)), to: &rooms)
    let model = try XCTUnwrap(rooms["!a:relais"])
    XCTAssertEqual(model.typingLabelFR(now: Date(), selfUserID: moi), "Alice écrit…")
  }

  func testUneListeVideVeutDireQuePersonneNEcritPlus() throws {
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = ["!a:relais": model(typing: ["@x:relais"])]
    let json = """
    {"next_batch":"s2","rooms":{"join":{"!a:relais":{
      "ephemeral":{"events":[{"type":"m.typing","content":{"user_ids":[]}}]}}}}}
    """
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)), to: &rooms)
    XCTAssertNil(rooms["!a:relais"]?.typingLabelFR(now: Date(), selfUserID: moi))
  }

  func testLIndicateurExpireToutSeul() {
    let model = self.model(typing: ["@x:relais"], names: ["@x:relais": "Alice"])
    XCTAssertEqual(model.typingLabelFR(now: maintenant, selfUserID: moi), "Alice écrit…")
    let tropTard = model.typingUpdatedAt.addingTimeInterval(MatrixRoomModel.typingLifetime + 1)
    XCTAssertNil(model.typingLabelFR(now: tropTard, selfUserID: moi))
  }

  func testMaPropreFrappeNeMAnnoncePasAMoiMeme() {
    let model = self.model(typing: [moi], names: [moi: "Moi"])
    XCTAssertNil(model.typingLabelFR(now: maintenant, selfUserID: moi))
  }

  func testLeLibelleSuitLeNombreDePersonnes() {
    let deux = model(
      typing: ["@x:relais", "@y:relais"],
      names: ["@x:relais": "Alice", "@y:relais": "Bruno"]
    )
    XCTAssertEqual(deux.typingLabelFR(now: maintenant, selfUserID: moi), "Alice et Bruno écrivent…")

    let trois = model(
      typing: ["@x:relais", "@y:relais", "@z:relais"],
      names: ["@x:relais": "Alice", "@y:relais": "Bruno", "@z:relais": "Camille"]
    )
    XCTAssertEqual(trois.typingLabelFR(now: maintenant, selfUserID: moi), "3 personnes écrivent…")
  }

  func testSansNomOnDitQuelquUnPlutotQueLIdentifiantDuPont() {
    let model = self.model(typing: ["@whatsapp_lid-99:relais"])
    XCTAssertEqual(model.typingLabelFR(now: maintenant, selfUserID: moi), "Quelqu'un écrit…")
  }
}
