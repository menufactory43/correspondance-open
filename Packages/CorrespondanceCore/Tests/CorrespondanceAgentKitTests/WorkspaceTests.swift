import XCTest

@testable import CorrespondanceAgentKit

/// Le dossier d'un tour est le rayon d'explosion : depuis la pleine permission,
/// c'est lui qui borne le risque, pas une question posée à l'utilisateur.
final class WorkspaceTests: XCTestCase {
  let home = URL(fileURLWithPath: "/Users/moi")

  func testSansDepotLieLeTourTravailleDansLeDossierDeSaRoom() {
    let path = Workspace.directory(agent: "cc", roomID: "!AbCd:correspondance.local", binding: nil, home: home)
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-agent/ateliers/"), path)
    XCTAssertTrue(path.contains("AbCd-correspondance.local"), path)
  }

  func testDeuxRoomsNePartagentJamaisLeMemeDossier() {
    let une = Workspace.directory(agent: "cc", roomID: "!une:local", binding: nil, home: home)
    let autre = Workspace.directory(agent: "cc", roomID: "!autre:local", binding: nil, home: home)
    XCTAssertNotEqual(une, autre)
  }

  /// Trouvé en vrai : `~/Correspondance/cc/<room>` et le dépôt `~/correspondance`
  /// sont le même dossier sur un disque insensible à la casse, et cc y a écrit.
  func testLeBacASableNeSeConfondJamaisAvecUnDepotHomonyme() {
    let path = Workspace.directory(agent: "cc", roomID: "!une:local", binding: nil, home: home)
    XCTAssertFalse(path.lowercased().hasPrefix("/users/moi/correspondance/"), path)
    XCTAssertTrue(path.hasPrefix("/Users/moi/."), "le bac à sable vit dans un dossier caché : \(path)")
  }

  func testUnAutreAgentTravailleSousSonPropreDossierCache() {
    let path = Workspace.directory(agent: "hermes", roomID: "!une:local", binding: nil, home: home)
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-hermes/ateliers/"), path)
  }

  func testDeuxAgentsNePartagentJamaisLeMemeDossier() {
    let cc = Workspace.directory(agent: "cc", roomID: "!une:local", binding: nil, home: home)
    let hermes = Workspace.directory(agent: "hermes", roomID: "!une:local", binding: nil, home: home)
    XCTAssertNotEqual(cc, hermes)
  }

  func testJamaisLaMaisonMemeSiLaConfigLeDemande() {
    let path = Workspace.directory(agent: "cc", roomID: "!une:local", binding: "/Users/moi", home: home)
    XCTAssertNotEqual(path, "/Users/moi")
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-agent/ateliers/"), path)
  }

  func testJamaisLaRacine() {
    let path = Workspace.directory(agent: "cc", roomID: "!une:local", binding: "/", home: home)
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-agent/ateliers/"), path)
  }

  func testUnCheminRelatifNeSortPasDuBacASable() {
    let path = Workspace.directory(agent: "cc", roomID: "!une:local", binding: "../ailleurs", home: home)
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-agent/ateliers/"), path)
  }

  func testUnDepotLieExplicitementEstRespecte() {
    let path = Workspace.directory(agent: "cc", roomID: "!une:local", binding: "/Users/moi/projets/app", home: home)
    XCTAssertEqual(path, "/Users/moi/projets/app")
  }

  func testLesCaracteresDUnIdentifiantDeRoomNeFabriquentPasDeChemin() {
    let path = Workspace.directory(agent: "cc", roomID: "!../../etc:local", binding: nil, home: home)
    XCTAssertFalse(path.contains(".."), path)
    XCTAssertTrue(path.hasPrefix("/Users/moi/.correspondance-agent/ateliers/"), path)
  }
}
