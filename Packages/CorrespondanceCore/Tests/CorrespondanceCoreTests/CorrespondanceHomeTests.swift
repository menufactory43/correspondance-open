import XCTest

@testable import CorrespondanceCore

/// `CORRESPONDANCE_HOME` déplace les données d'un essai. La propriété qui ne se
/// négocie pas : **sans la variable, rien ne change** — ni le dossier, ni le
/// Trousseau. C'est ce qui protège les vraies conversations de meffysto.
final class CorrespondanceHomeTests: XCTestCase {

  // MARK: - Sans la variable

  func testSansLaVariableLeDossierEstCeluiDeToujours() {
    XCTAssertEqual(CorrespondanceHome.folderName(environment: [:]), "Correspondance")
  }

  func testSansLaVariableLeTrousseauEstCeluiDeToujours() {
    XCTAssertEqual(CorrespondanceHome.keychainService(environment: [:]), "app.correspondance.matrix")
  }

  func testUneVariableVideNeDeplaceRien() {
    // Un `export CORRESPONDANCE_HOME=` malheureux ne doit pas fabriquer un
    // dossier « Correspondance- » orphelin.
    for vide in ["", "   ", "---", "__"] {
      XCTAssertEqual(CorrespondanceHome.folderName(environment: ["CORRESPONDANCE_HOME": vide]), "Correspondance", vide)
      XCTAssertEqual(
        CorrespondanceHome.keychainService(environment: ["CORRESPONDANCE_HOME": vide]),
        "app.correspondance.matrix", vide
      )
    }
  }

  // MARK: - Avec la variable

  func testAvecLaVariableToutBasculeEnsemble() {
    let essai = ["CORRESPONDANCE_HOME": "essai"]
    XCTAssertEqual(CorrespondanceHome.folderName(environment: essai), "Correspondance-essai")
    XCTAssertEqual(CorrespondanceHome.keychainService(environment: essai), "app.correspondance.matrix.essai")
  }

  /// Le point de tout ce fichier : les deux moitiés bougent, ou aucune. Une
  /// base déplacée avec le Trousseau d'origine écraserait la vraie session.
  func testLesDeuxMoitiesNeSeSeparentJamais() {
    for nom in ["essai", "demo", "bac-a-sable"] {
      let environnement = ["CORRESPONDANCE_HOME": nom]
      let dossier = CorrespondanceHome.folderName(environment: environnement)
      let trousseau = CorrespondanceHome.keychainService(environment: environnement)
      XCTAssertNotEqual(dossier, CorrespondanceHome.defaultFolder, nom)
      XCTAssertNotEqual(trousseau, CorrespondanceHome.defaultKeychainService, nom)
      XCTAssertTrue(dossier.hasSuffix(nom), dossier)
      XCTAssertTrue(trousseau.hasSuffix(nom), trousseau)
    }
  }

  func testDeuxEssaisNeSeMelangentPas() {
    XCTAssertNotEqual(
      CorrespondanceHome.folderName(environment: ["CORRESPONDANCE_HOME": "un"]),
      CorrespondanceHome.folderName(environment: ["CORRESPONDANCE_HOME": "deux"])
    )
  }

  // MARK: - Ce qu'un nom n'a pas le droit de faire

  /// Même garde que `Workspace` côté agent : un nom ne fabrique pas de chemin.
  func testUnNomNeSortPasDuDossier() {
    let mechants = ["../../etc", "/etc/passwd", "..", "a/b/c", "essai/../.."]
    for mechant in mechants {
      let dossier = CorrespondanceHome.folderName(environment: ["CORRESPONDANCE_HOME": mechant])
      XCTAssertFalse(dossier.contains(".."), dossier)
      XCTAssertFalse(dossier.contains("/"), dossier)
      XCTAssertTrue(dossier.hasPrefix("Correspondance"), dossier)
    }
  }

  func testUnNomNeCasseNiLeTrousseauNiSonService() {
    let service = CorrespondanceHome.keychainService(environment: ["CORRESPONDANCE_HOME": "../autre"])
    XCTAssertFalse(service.contains("/"), service)
    XCTAssertFalse(service.contains(".."), service)
  }

  func testLeDossierSeCreeEtPorteLeNomDeLEssai() throws {
    let racine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: racine) }

    let dossier = CorrespondanceHome.directory(environment: ["CORRESPONDANCE_HOME": "essai"], base: racine)
    XCTAssertEqual(dossier.lastPathComponent, "Correspondance-essai")
    // Il existe : les stores écrivent dedans sans le créer eux-mêmes.
    XCTAssertTrue(FileManager.default.fileExists(atPath: dossier.path()))

    let normal = CorrespondanceHome.directory(environment: [:], base: racine)
    XCTAssertEqual(normal.lastPathComponent, "Correspondance")
    XCTAssertNotEqual(normal, dossier, "l'essai et le vrai ne partagent aucun fichier")
  }

  func testOnSaitDireQuOnEstEnEssai() {
    XCTAssertNil(CorrespondanceHome.resolvedName(from: [:]))
    XCTAssertEqual(CorrespondanceHome.resolvedName(from: ["CORRESPONDANCE_HOME": "essai"]), "essai")
  }
}
