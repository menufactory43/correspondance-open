import XCTest
@testable import CorrespondanceCore

/// **Par où** un code d'appairage se joint. C'est ce que la feuille du code
/// annonce avant de se connecter, et c'est calculable sans réseau : d'où ces
/// tests, qui sont ceux de la vue-modèle des deux écrans d'appairage.
final class CheminDuRelaisTests: XCTestCase {

  private func code(_ adresse: String, tailcat: String? = nil) -> RelayPairingCode {
    RelayPairingCode(
      homeserver: URL(string: adresse)!, serverName: "unclic.local",
      user: "essai", password: "s3cr3t",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000), tailcat: tailcat)
  }

  func testUnJetonTailcatDecideDeTout() {
    // Même quand l'adresse est celle d'un tailnet : Tailcat est le chemin par
    // défaut depuis la phase 7b, et l'écran doit dire ce qui sera pris.
    XCTAssertEqual(code("http://100.101.1.2:8010", tailcat: "tcXYZ").chemin, .tailcat)
    XCTAssertEqual(code("http://127.0.0.1:8010", tailcat: "tcXYZ").chemin, .tailcat)
  }

  func testUnJetonVideNEnEstPasUn() {
    // Un champ présent mais vide serait pire qu'absent : il ferait afficher
    // « via Tailcat » à un code qui n'ouvre aucun chemin.
    XCTAssertEqual(code("http://127.0.0.1:8010", tailcat: "").chemin, .memeMachine)
  }

  func testUneAdresseDeTailnetSeReconnait() {
    XCTAssertEqual(code("http://100.101.1.2:8010").chemin, .tailscale)
    XCTAssertEqual(code("http://relais.exemple.ts.net:8008").chemin, .tailscale)
  }

  func testUneAdresseEn100QuiNestPasUnTailnet() {
    // 100.64.0.0/10, et rien d'autre : 100.200.1.1 est une adresse publique
    // ordinaire, et la dire « Tailscale » serait un mensonge à l'écran.
    XCTAssertEqual(code("http://100.200.1.1:8010").chemin, .adresse)
    XCTAssertEqual(code("http://100.63.1.1:8010").chemin, .adresse)
    XCTAssertEqual(code("http://100.64.0.1:8010").chemin, .tailscale)
    XCTAssertEqual(code("http://100.127.255.254:8010").chemin, .tailscale)
  }

  func testLaMemeMachine() {
    XCTAssertEqual(code("http://127.0.0.1:8010").chemin, .memeMachine)
    XCTAssertEqual(code("http://localhost:8010").chemin, .memeMachine)
  }

  func testUneAdresseOrdinaire() {
    XCTAssertEqual(code("http://192.168.1.20:8010").chemin, .adresse)
    XCTAssertEqual(code("https://relais.exemple.fr").chemin, .adresse)
  }

  func testChaqueCheminSeDitEnFrancais() {
    XCTAssertEqual(CheminDuRelais.tailcat.titreFR, "via Tailcat")
    XCTAssertEqual(CheminDuRelais.tailscale.titreFR, "via Tailscale")
    for chemin: CheminDuRelais in [.tailcat, .tailscale, .memeMachine, .adresse] {
      XCTAssertFalse(chemin.titreFR.isEmpty)
      XCTAssertFalse(chemin.detailFR.isEmpty)
    }
    // Le seul chemin qui parle encore de l'iPhone est celui qui le concerne :
    // Tailcat marche sur ce Mac et pas sur l'iPhone, et l'écran le dit là.
    XCTAssertTrue(CheminDuRelais.tailcat.detailFR.contains("iPhone"))
  }
}
