import CorrespondanceCore
import XCTest

@testable import Correspondance

/// Ce que la carte « Sur ce Mac » fait avant de lancer quoi que ce soit :
/// vérifier la somme du script, puis lire le flux de l'installeur. Les deux
/// sont purs, donc éprouvés ici sans réseau ni processus enfant.
final class RelaisInstallationTests: XCTestCase {

  // MARK: - Le flux JSON

  func testUneEtapeSeLit() {
    let evenement = RelaisFlux.analyser(
      ligne: #"{"etape":"binaires","etat":"debut","detail":"continuwuity v26.8.1"}"#)
    XCTAssertEqual(
      evenement,
      .etape(RelaisEtape(etape: "binaires", etat: .debut, detail: "continuwuity v26.8.1")))
  }

  func testLesLignesPourLHumainSontIgnorees() {
    // L'installeur parle aux deux à la fois : ses phrases « → … » passent dans
    // le même tuyau. Une ligne illisible ne doit jamais faire échouer une
    // installation — elle doit seulement ne rien afficher.
    XCTAssertNil(RelaisFlux.analyser(ligne: "→ continuwuity : sha256 ✓"))
    XCTAssertNil(RelaisFlux.analyser(ligne: ""))
    XCTAssertNil(RelaisFlux.analyser(ligne: "{ ceci n'est pas du JSON"))
    XCTAssertNil(RelaisFlux.analyser(ligne: #"{"autre":"objet"}"#))
  }

  func testUnEtatInconnuNEstPasUneEtape() {
    // Mieux vaut ne rien montrer qu'inventer un état : l'écran dirait « ok »
    // sur un mot qu'il ne connaît pas.
    XCTAssertNil(RelaisFlux.analyser(ligne: #"{"etape":"ponts","etat":"peut-être"}"#))
  }

  func testLAppairageSeReconnaitASonCodePasASonNom() {
    let code = RelayPairingCode(
      homeserver: URL(string: "http://127.0.0.1:8010")!, serverName: "unclic.local",
      user: "essai", password: "motdepasse"
    ).encoded()
    let ligne = #"{"etape":"appairage","etat":"ok","code":"\#(code)","mots":["arbre","banc","cabane","dune","encre","falaise"]}"#
    XCTAssertEqual(
      RelaisFlux.analyser(ligne: ligne),
      .appairage(code: code, mots: ["arbre", "banc", "cabane", "dune", "encre", "falaise"]))
  }

  func testUneEtapeNommeeAppairageSansCodeNEstPasLaFin() {
    // Le défaut qu'on évite : l'app se croirait prête et n'attendrait plus le
    // vrai code. C'est le contenu qui décide, pas le nom.
    XCTAssertEqual(
      RelaisFlux.analyser(ligne: #"{"etape":"appairage","etat":"debut","detail":"…"}"#),
      .etape(RelaisEtape(etape: "appairage", etat: .debut, detail: "…")))
  }

  func testUneEtapeQuiFinitRemplaceSonDebut() {
    // Sans ça la liste double à chaque étape, et personne ne sait où on en est.
    var liste = RelaisFlux.fusionner([], avec: RelaisEtape(etape: "binaires", etat: .debut, detail: "…"))
    liste = RelaisFlux.fusionner(liste, avec: RelaisEtape(etape: "binaires", etat: .ok, detail: "posés"))
    XCTAssertEqual(liste.count, 1)
    XCTAssertEqual(liste.first?.etat, .ok)
  }

  func testDeuxEtapesDifferentesSempilent() {
    var liste = RelaisFlux.fusionner([], avec: RelaisEtape(etape: "binaires", etat: .ok, detail: ""))
    liste = RelaisFlux.fusionner(liste, avec: RelaisEtape(etape: "services", etat: .debut, detail: ""))
    XCTAssertEqual(liste.map(\.etape), ["binaires", "services"])
  }

  func testChaqueEtapeAUnNomEnFrancais() {
    // Un identifiant d'étape à l'écran, c'est une fuite d'implémentation.
    for nom in ["prerequis", "binaires", "secrets", "configuration", "services",
                "attente", "compte", "ponts", "preuve", "appairage"] {
      let etape = RelaisEtape(etape: nom, etat: .ok, detail: "")
      XCTAssertNotEqual(etape.libelleFR, nom, "l'étape « \(nom) » n'a pas de libellé")
    }
  }

  // MARK: - Les sommes

  private let sommes = """
    2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae  relais-install.sh
    fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9  relais-uninstall.sh
    a7b4dd2099dd349631b24c3f3970cb440fb9365a3aa406830995d389fae16f77  continuwuity-macos-arm64
    """

  func testLaSommeSeTrouveParSonNom() {
    XCTAssertEqual(
      RelaisSommes.attendue(pour: "relais-install.sh", dans: sommes),
      "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae")
    XCTAssertEqual(
      RelaisSommes.attendue(pour: "continuwuity-macos-arm64", dans: sommes),
      "a7b4dd2099dd349631b24c3f3970cb440fb9365a3aa406830995d389fae16f77")
  }

  func testUnFichierAbsentDuSHA256SUMSNaPasDeSomme() {
    // Et l'installateur refuse alors d'exécuter : c'est le cas d'un dépôt de
    // publication à moitié à jour, qui est exactement quand il faut s'arrêter.
    XCTAssertNil(RelaisSommes.attendue(pour: "relais-install.sh.bak", dans: sommes))
  }

  func testLeFormatBinaireDeShasumSeLitAussi() {
    // `shasum -b` écrit « <somme> *<nom> ». Les deux formats circulent.
    XCTAssertEqual(
      RelaisSommes.attendue(
        pour: "relais-install.sh",
        dans: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae *relais-install.sh"),
      "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae")
  }

  func testUnCommentaireNEstPasPrisPourUneSomme() {
    XCTAssertNil(RelaisSommes.attendue(
      pour: "relais-install.sh", dans: "# sommes des binaires relais-install.sh"))
  }

  func testLaSommeDunContenuConnu() {
    // sha256("abc") — la valeur de référence de la spécification.
    XCTAssertEqual(
      RelaisSommes.somme(de: Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testUnScriptQuiNeCorrespondPasEstRefuse() {
    let donnees = Data("bonjour".utf8)
    let vraie = RelaisSommes.somme(de: donnees)
    XCTAssertTrue(RelaisSommes.verifier(donnees: donnees, attendue: vraie))
    XCTAssertTrue(RelaisSommes.verifier(donnees: donnees, attendue: vraie.uppercased()))
    // Un octet de plus, et c'est non : c'est tout l'objet du contrôle.
    XCTAssertFalse(RelaisSommes.verifier(donnees: Data("bonjour ".utf8), attendue: vraie))
  }

  func testLAdresseDesReleasesEstConfigurable() {
    // La preuve de la phase 6 tient à ça : `CORRESPONDANCE_RELEASES` pointe sur
    // un serveur local, et rien d'autre ne change.
    let vue = RelaisInstallateur.releases
    if let posee = ProcessInfo.processInfo.environment["CORRESPONDANCE_RELEASES"] {
      XCTAssertEqual(vue, posee)
    } else {
      XCTAssertTrue(vue.hasPrefix("https://"), "l'adresse par défaut doit être publique et en https")
    }
  }
}
