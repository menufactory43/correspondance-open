import XCTest

@testable import CorrespondanceCore

/// Les six mots sont calculés deux fois : ici, en Swift, et dans
/// `infra/matrix/pair.sh`, en Python, sur la machine du Relais. Deux
/// implémentations qui divergeraient rendraient la vérification inutile — pire,
/// elles feraient croire à une erreur là où il n'y en a pas.
///
/// La valeur ci-dessous a été produite par le script. Si ce test tombe, c'est
/// que l'un des deux a changé, et il faut reprendre l'autre.
final class RelayPairingWordsTests: XCTestCase {
  func testLesMotsSontLesMemesQueCeuxDuScriptDInstallation() {
    let code = RelayPairingCode(
      homeserver: URL(string: "http://100.64.0.1:8008")!,
      serverName: "correspondance.local",
      user: "meffysto",
      password: "peu importe",
      expiresAt: Date(timeIntervalSince1970: 0)
    )
    XCTAssertEqual(
      code.fingerprintWords(),
      ["chêne", "falaise", "dune", "givre", "flotte", "sable"],
      "produit par : infra/matrix/pair.sh"
    )
  }
}
