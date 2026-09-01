import XCTest
@testable import CorrespondanceCore

/// « Vu par Alice et Bruno » : dans un groupe, le marqueur `m.read` de chaque
/// membre dit qui a lu mon dernier message. En DM, le « Vu » simple suffit.
final class SeenByTests: XCTestCase {
  private let moi = "@meffysto:relais"

  /// Un groupe où j'ai parlé en dernier (`$moi` à t=100), et où chacun a un
  /// message plus ancien (t=10) qui peut servir de marqueur « lu jusqu'ici ».
  private func groupe(members: [String: String]) -> MatrixRoomModel {
    var model = MatrixRoomModel(roomID: "!g:relais")
    model.bridgeRoomType = "group"
    for (id, name) in members {
      model.members[id] = .init(displayName: name, membership: "join")
    }
    model.members[moi] = .init(displayName: "Moi", membership: "join")
    model.messagesByID["$vieux"] = ChatMessage(
      id: "$vieux", conversationID: "c", network: .whatsapp, text: "avant",
      sentAt: Date(timeIntervalSince1970: 10), isFromMe: false
    )
    model.messagesByID["$moi"] = ChatMessage(
      id: "$moi", conversationID: "c", network: .whatsapp, text: "mon dernier",
      sentAt: Date(timeIntervalSince1970: 100), isFromMe: true
    )
    return model
  }

  func testPersonneNALuRienNeSAffiche() {
    let model = groupe(members: ["@a:relais": "Alice"])
    XCTAssertNil(model.seenByLabelFR(selfUserID: moi))
    XCTAssertEqual(model.delivery(selfUserID: moi), .sent)
  }

  func testUnMarqueurEnRetardNeComptePas() {
    var model = groupe(members: ["@a:relais": "Alice", "@b:relais": "Bruno"])
    model.readMarkerByUser["@a:relais"] = "$vieux"
    XCTAssertNil(model.seenByLabelFR(selfUserID: moi))
  }

  func testUneLectriceEstNommee() {
    var model = groupe(members: ["@a:relais": "Alice", "@b:relais": "Bruno"])
    model.readMarkerByUser["@a:relais"] = "$moi"
    XCTAssertEqual(model.seenByLabelFR(selfUserID: moi), "Vu par Alice")
    XCTAssertEqual(model.delivery(selfUserID: moi), .read)
  }

  func testToutLeGroupeALu() {
    var model = groupe(members: ["@a:relais": "Alice", "@b:relais": "Bruno"])
    model.readMarkerByUser["@a:relais"] = "$moi"
    model.readMarkerByUser["@b:relais"] = "$moi"
    XCTAssertEqual(model.seenByLabelFR(selfUserID: moi), "Vu par tout le monde")
  }

  func testTroisLecteursSurQuatreSontNommes() {
    var model = groupe(members: [
      "@a:relais": "Alice", "@b:relais": "Bruno",
      "@c:relais": "Chloé", "@d:relais": "David",
    ])
    for id in ["@a:relais", "@b:relais", "@c:relais"] {
      model.readMarkerByUser[id] = "$moi"
    }
    XCTAssertEqual(model.seenByLabelFR(selfUserID: moi), "Vu par Alice, Bruno et Chloé")
  }

  func testAuDelaDeTroisOnCompte() {
    var model = groupe(members: [
      "@a:relais": "Alice", "@b:relais": "Bruno", "@c:relais": "Chloé",
      "@d:relais": "David", "@e:relais": "Emma", "@f:relais": "Fanny",
    ])
    for id in ["@a:relais", "@b:relais", "@c:relais", "@d:relais"] {
      model.readMarkerByUser[id] = "$moi"
    }
    XCTAssertEqual(model.seenByLabelFR(selfUserID: moi), "Vu par Alice, Bruno et 2 autres")
  }

  func testUnLecteurSansNomSeCompteSansSInventer() {
    var model = groupe(members: ["@a:relais": "", "@b:relais": "Bruno"])
    model.readMarkerByUser["@a:relais"] = "$moi"
    XCTAssertEqual(model.seenByLabelFR(selfUserID: moi), "Vu par 1 personne")
  }

  func testLAgentCcNEstPasUnLecteur() {
    var model = groupe(members: ["@a:relais": "Alice", "@b:relais": "Bruno"])
    model.members["@cc:relais"] = .init(displayName: "cc", membership: "join")
    model.readMarkerByUser["@cc:relais"] = "$moi"
    XCTAssertNil(model.seenByLabelFR(selfUserID: moi))
    // Sa lecture ne vaut pas non plus un « Vu » anonyme.
    XCTAssertEqual(model.delivery(selfUserID: moi), .sent)
  }

  /// Le pluriel a coûté un défaut : seul « cc » était écarté, donc un salon où
  /// vivait un second agent affichait « Vu » dès que celui-là avait synchronisé
  /// — un accusé de lecture pour personne.
  func testAucunAgentNEstUnLecteur() {
    var model = groupe(members: ["@a:relais": "Alice"])
    model.members["@hermes:relais"] = .init(displayName: "hermes", membership: "join")
    model.readMarkerByUser["@hermes:relais"] = "$moi"
    XCTAssertNil(model.seenByLabelFR(selfUserID: moi))
    XCTAssertEqual(model.delivery(selfUserID: moi), .sent)
  }

  func testEnDMLeDetailSeTait() {
    var model = groupe(members: ["@a:relais": "Alice"])
    model.bridgeRoomType = "dm"
    model.readMarkerByUser["@a:relais"] = "$moi"
    XCTAssertNil(model.seenByLabelFR(selfUserID: moi))
    XCTAssertEqual(model.delivery(selfUserID: moi), .read)
  }
}
