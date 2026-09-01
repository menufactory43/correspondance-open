import XCTest

@testable import Correspondance

/// Le catalogue des moteurs de ce Mac. Ce qui est éprouvé ici, c'est la
/// **décision** : « prêt » ne se dit qu'après avoir vu un binaire, et un
/// adaptateur ACP d'une version qu'on n'a pas éprouvée n'est jamais « prêt ».
final class EngineCatalogTests: XCTestCase {

  private func entree(_ id: String) throws -> EngineCatalog.Entry {
    try XCTUnwrap(EngineCatalog.entries.first { $0.id == id }, "\(id) manque au catalogue")
  }

  // MARK: - La décision

  func testSansBinaireLeMoteurNEstPasInstalle() throws {
    let claude = try entree("claude")
    XCTAssertEqual(EngineCatalog.decide(entry: claude, path: nil, version: "1.2.3"), .nonInstalle)
  }

  func testUnMoteurTrouveEstPretAvecSaVersion() throws {
    let claude = try entree("claude")
    XCTAssertEqual(
      EngineCatalog.decide(entry: claude, path: "/opt/homebrew/bin/claude", version: "2.0.1 (Claude Code)"),
      .pret(version: "2.0.1 (Claude Code)")
    )
  }

  /// Un moteur sans version épinglée reste prêt même s'il ne sait pas dire sa
  /// version : `hermes --version` ne répond pas toujours, et ça ne l'empêche
  /// pas de tourner.
  func testUnMoteurSansVersionEpingleeRestePret() throws {
    let hermes = try entree("hermes")
    XCTAssertEqual(
      EngineCatalog.decide(entry: hermes, path: "/Users/moi/.local/bin/hermes", version: nil),
      .pret(version: nil)
    )
  }

  /// Le cas qui justifie tout le reste : le régime de permission par défaut
  /// d'un adaptateur change d'une version à l'autre — `claude-agent-acp`
  /// 0.70.0 démarrait en mode `auto` et a exécuté un `Bash` sans rien demander.
  /// Une version qu'on n'a pas éprouvée n'est donc pas « prête ».
  func testUnAdaptateurACPHorsVersionEpingleeNEstPasPret() throws {
    let acp = try entree("claude-code-acp")
    let etat = EngineCatalog.decide(
      entry: acp, path: "/opt/homebrew/bin/claude-code-acp", version: "claude-code-acp 0.19.0"
    )
    XCTAssertEqual(etat, .adaptateurPerime(version: "0.19.0", epinglee: EngineCatalog.acpVersionEpinglee))
    XCTAssertFalse(etat.estPret)
    XCTAssertTrue(etat.labelFR.contains("0.19.0"), etat.labelFR)
  }

  func testUnAdaptateurACPALaVersionEpingleeEstPret() throws {
    let acp = try entree("claude-code-acp")
    let etat = EngineCatalog.decide(
      entry: acp, path: "/opt/homebrew/bin/claude-code-acp",
      version: "claude-code-acp \(EngineCatalog.acpVersionEpinglee)"
    )
    XCTAssertTrue(etat.estPret, etat.labelFR)
  }

  /// Un adaptateur muet sur sa version n'est pas « prêt » non plus : on ne
  /// peut pas affirmer qu'elle est la bonne, donc on ne l'affirme pas.
  func testUnAdaptateurQuiNeDitPasSaVersionNEstPasPret() throws {
    let acp = try entree("claude-code-acp")
    let etat = EngineCatalog.decide(entry: acp, path: "/usr/local/bin/claude-code-acp", version: nil)
    XCTAssertFalse(etat.estPret)
  }

  func testLeNumeroDeVersionSeLitDansUneLigneQuelconque() {
    XCTAssertEqual(EngineCatalog.numeroDeVersion("claude-code-acp 0.16.2"), "0.16.2")
    XCTAssertEqual(EngineCatalog.numeroDeVersion("goose 1.9.0 (build 42)"), "1.9.0")
    XCTAssertEqual(EngineCatalog.numeroDeVersion("v2.0.1"), "2.0.1")
    XCTAssertNil(EngineCatalog.numeroDeVersion("aucune version ici"))
  }

  // MARK: - Le scan, avec des sondes injectées

  func testLeScanNAffirmeQueCeQuIlAVu() {
    let trouves = ["hermes": "/Users/moi/.local/bin/hermes"]
    let resultats = EngineCatalog.scan(
      which: { trouves[$0] },
      version: { _ in "1.0.0" }
    )
    XCTAssertEqual(resultats.count, EngineCatalog.entries.count)
    let hermes = resultats.first { $0.entry.id == "hermes" }
    XCTAssertEqual(hermes?.path, "/Users/moi/.local/bin/hermes")
    XCTAssertTrue(hermes?.state.estPret == true)
    // Tous les autres manquent, et aucun ne se dit prêt.
    for resultat in resultats where resultat.entry.id != "hermes" {
      XCTAssertEqual(resultat.state, .nonInstalle, resultat.entry.id)
    }
  }

  // MARK: - Les chemins, et le PATH qui ment

  /// L'installeur d'Hermes pose son binaire dans `~/.local/bin`, hors du PATH
  /// de la plupart des shells non-login — et le PATH d'un enfant de l'app est
  /// encore plus pauvre. La découverte doit donc être la nôtre.
  func testOnCherchePartoutOuLesInstalleursPosent() {
    let chemins = EngineCatalog.cheminsCandidats("hermes", home: "/Users/moi")
    XCTAssertEqual(chemins.first, "/Users/moi/.local/bin/hermes")
    XCTAssertTrue(chemins.contains("/opt/homebrew/bin/hermes"))
    XCTAssertTrue(chemins.contains("/usr/local/bin/hermes"))
  }

  // MARK: - Le catalogue tient avec l'installeur

  /// La version épinglée est écrite à deux endroits : ici, et dans
  /// `infra/agent/install.sh` (`ACP_PACKAGE`), qui est ce que l'installation
  /// pose vraiment sur un hôte distant. Deux endroits qui divergent au premier
  /// `npm update`, c'est un écran qui dirait « prêt » d'un adaptateur que
  /// l'hôte n'a pas.
  func testLaVersionEpingleeEstCelleDeLInstalleur() throws {
    let racine = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CorrespondanceTests
      .deletingLastPathComponent()  // racine du dépôt
    let script = racine.appending(path: "infra/agent/install.sh")
    guard let contenu = try? String(contentsOf: script, encoding: .utf8) else {
      throw XCTSkip("install.sh hors de portée depuis ce bundle de test")
    }
    let ligne = try XCTUnwrap(
      contenu.split(separator: "\n").first { $0.hasPrefix("ACP_PACKAGE=") },
      "ACP_PACKAGE a disparu de l'installeur"
    )
    XCTAssertTrue(
      ligne.contains("@\(EngineCatalog.acpVersionEpinglee)"),
      "l'installeur pose « \(ligne) », le catalogue épingle \(EngineCatalog.acpVersionEpinglee)"
    )
  }

  /// Chaque moteur du catalogue dit comment l'installer : un moteur absent
  /// affiche cet indice, jamais un bouton qui mentirait.
  func testChaqueMoteurSaitDireCommentOnLInstalle() {
    for entree in EngineCatalog.entries {
      XCTAssertFalse(entree.indiceInstallation.isEmpty, entree.id)
      XCTAssertFalse(entree.nomAgentPropose.isEmpty, entree.id)
      if entree.backend == .acp {
        XCTAssertNotNil(entree.acpCommand, "\(entree.id) : un backend acp a besoin de sa commande")
      }
    }
  }
}
