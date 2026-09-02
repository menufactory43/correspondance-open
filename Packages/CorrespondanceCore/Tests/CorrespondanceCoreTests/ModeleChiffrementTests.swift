import XCTest
import CorrespondanceMatrixClient
@testable import CorrespondanceCore

/// Un Relais de papier : il ne fait pas de réseau, il répond ce qu'on lui dit
/// de répondre et note ce qu'on lui a demandé. C'est tout ce qu'il faut pour
/// éprouver la seule vraie question des deux écrans — **quoi montrer, quand**.
private actor RelaisDePapier: ChiffrementDuCompte {
  var etatRendu: MatrixEtatChiffrement
  var versionDistante: String?
  var appareilsRendus: [MatrixAppareilVu]
  var importRendu = MatrixImportDeCles(importees: 10, total: 10)
  var refuseLaPhrase = false
  var deconnexionRendue: MatrixDeconnexionAppareil = .faite

  private(set) var phrasesCreees: [String] = []
  private(set) var phrasesRejointes: [String] = []
  private(set) var phrasesAuCoffre: [String] = []
  private(set) var deconnexions: [(String, String?)] = []
  private(set) var signaturesAmorcees = 0

  init(
    etat: MatrixEtatChiffrement = MatrixEtatChiffrement(actif: true, appareilID: "MOI"),
    versionDistante: String? = nil,
    appareils: [MatrixAppareilVu] = []
  ) {
    self.etatRendu = etat
    self.versionDistante = versionDistante
    self.appareilsRendus = appareils
  }

  func etat() async -> MatrixEtatChiffrement { etatRendu }
  func versionDeSauvegarde() async -> String? { versionDistante }
  func appareils() async -> [MatrixAppareilVu] { appareilsRendus }

  func creerSauvegarde(phrase: String, remplacer: Bool) async throws -> Int {
    phrasesCreees.append(phrase)
    versionDistante = "7"
    etatRendu.sauvegardeVersion = "7"
    return 10
  }

  func rejoindreSauvegarde(phrase: String) async throws -> MatrixImportDeCles {
    if refuseLaPhrase { throw MatrixError.decoding("phrase") }
    phrasesRejointes.append(phrase)
    etatRendu.sauvegardeVersion = versionDistante
    return importRendu
  }

  func deposerLesSignatures(phrase: String) async throws { phrasesAuCoffre.append(phrase) }
  func amorcerLesSignatures(motDePasse: String?) async throws { signaturesAmorcees += 1 }

  func deconnecterAppareil(_ deviceID: String, motDePasse: String?) async throws
    -> MatrixDeconnexionAppareil
  {
    deconnexions.append((deviceID, motDePasse))
    if case .motDePasseRequis = deconnexionRendue, motDePasse != nil {
      appareilsRendus.removeAll { $0.deviceID == deviceID }
      return .faite
    }
    if case .faite = deconnexionRendue { appareilsRendus.removeAll { $0.deviceID == deviceID } }
    return deconnexionRendue
  }
}

private final class MagasinEnMemoire: MagasinDePhrase, @unchecked Sendable {
  private var contenu: [String: String] = [:]
  func lire(compte: String) -> String? { contenu[compte] }
  func ecrire(_ phrase: String, compte: String) { contenu[compte] = phrase }
  func effacer(compte: String) { contenu[compte] = nil }
}

@MainActor
final class ModeleChiffrementTests: XCTestCase {

  // MARK: - Le lexique et la phrase

  func testLeLexiqueFaitExactementDeuxCentCinquanteSixMotsDistincts() {
    // 8 bits par mot n'est vrai qu'à ce nombre-là : un mot en plus ou en moins
    // déplacerait l'entropie sans que rien ne le dise.
    XCTAssertEqual(PhraseDeRecuperation.lexique.count, 256)
    XCTAssertEqual(Set(PhraseDeRecuperation.lexique).count, 256)
  }

  func testLaPhraseFaitDouzeMotsDuLexique() {
    let phrase = PhraseDeRecuperation.engendrer()
    let mots = phrase.split(separator: " ").map(String.init)
    XCTAssertEqual(mots.count, 12)
    for mot in mots { XCTAssertTrue(PhraseDeRecuperation.lexique.contains(mot), mot) }
  }

  func testDeuxPhrasesTireesNeSeRessemblentPas() {
    XCTAssertNotEqual(PhraseDeRecuperation.engendrer(), PhraseDeRecuperation.engendrer())
  }

  func testUneSaisieRecopieeAvecMajusculesEtEspacesResteLaMemePhrase() {
    // Le correcteur d'iOS met une majuscule au premier mot, et une note collée
    // porte des retours à la ligne. La clé, elle, est dérivée d'une chaîne
    // exacte : sans la normalisation, une phrase juste serait refusée.
    XCTAssertEqual(
      PhraseDeRecuperation.normaliser("  Abri   acier\nAigle "), "abri acier aigle")
  }

  func testUneSaisieTropCourteEstRefuseeSansAllerAuRelais() {
    XCTAssertFalse(PhraseDeRecuperation.semblePlausible("abri acier"))
    XCTAssertTrue(PhraseDeRecuperation.semblePlausible("un deux trois quatre cinq six"))
  }

  // MARK: - Ce que l'écran montre, et quand

  func testSansSauvegardeSurLeRelaisOnProposeDenPoserUne() async {
    let modele = ModeleChiffrement(compte: "@moi:x", service: RelaisDePapier())
    await modele.sonder()
    XCTAssertEqual(modele.etape, .aProposer)
  }

  func testAppareilNeufFaceAUneSauvegardeExistanteOnDemandeLaPhrase() async {
    // Le fait qui décide : le Relais héberge une version que **cet** appareil
    // ne connaît pas. C'est la seule façon de distinguer un appareil neuf d'un
    // appareil déjà en règle — l'état local ne suffit pas.
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, sauvegardeVersion: nil, appareilID: "NEUF"),
      versionDistante: "4")
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    XCTAssertEqual(modele.etape, .aEntrer(version: "4"))
  }

  func testQuandLappareilConnaitDejaLaSauvegardeIlNyAPlusRienAFaire() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, sauvegardeVersion: "4", appareilID: "MOI"),
      versionDistante: "4")
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    XCTAssertEqual(modele.etape, .enPlace(version: "4", phraseConnue: false))
  }

  func testSansMachineCryptoLecranLeDitPlutotQueDeSeTaire() async {
    let relais = RelaisDePapier(etat: MatrixEtatChiffrement(actif: false))
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    guard case .indisponible = modele.etape else {
      return XCTFail("attendu .indisponible, reçu \(modele.etape)")
    }
    XCTAssertTrue(modele.appareils.isEmpty)
  }

  // MARK: - La phrase montrée une seule fois

  func testLaSauvegardeNeNaitQuAJeLaiNotee() async {
    let relais = RelaisDePapier()
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()

    modele.proposerUnePhrase()
    guard case let .aNoter(phrase) = modele.etape else {
      return XCTFail("attendu .aNoter, reçu \(modele.etape)")
    }
    // Rien n'est parti : une sauvegarde créée avant que la phrase soit lue
    // serait une sauvegarde que personne ne peut ouvrir.
    let avant = await relais.phrasesCreees
    XCTAssertTrue(avant.isEmpty)

    await modele.confirmerLaPhrase()
    let apres = await relais.phrasesCreees
    XCTAssertEqual(apres, [phrase])
    let coffre = await relais.phrasesAuCoffre
    XCTAssertEqual(coffre, [phrase], "les clés de signature doivent partir au coffre")
    XCTAssertEqual(modele.etape, .enPlace(version: "7", phraseConnue: false))
  }

  func testUnRafraichissementNeFaitPasDisparaitreLaPhraseNonNotee() async {
    // C'était le vrai risque : `sonder()` est appelé à chaque apparition de
    // l'écran, et il aurait effacé douze mots que personne n'avait recopiés —
    // en laissant, sur le Relais, une sauvegarde à jamais fermée.
    let modele = ModeleChiffrement(compte: "@moi:x", service: RelaisDePapier())
    await modele.sonder()
    modele.proposerUnePhrase()
    let avant = modele.etape
    await modele.sonder()
    XCTAssertEqual(modele.etape, avant)
  }

  func testRevoirNestProposeQueSiCetAppareilGardeLaPhrase() async {
    let magasin = MagasinEnMemoire()
    let modele = ModeleChiffrement(
      compte: "@moi:x", service: RelaisDePapier(), magasin: magasin)
    await modele.sonder()
    modele.revoirLaPhrase()
    XCTAssertNil(modele.phraseRevelee)
    XCTAssertNotNil(modele.message)

    modele.proposerUnePhrase()
    guard case let .aNoter(phrase) = modele.etape else { return XCTFail() }
    await modele.confirmerLaPhrase()
    XCTAssertEqual(modele.etape, .enPlace(version: "7", phraseConnue: true))
    modele.revoirLaPhrase()
    XCTAssertEqual(modele.phraseRevelee, phrase)
    modele.cacherLaPhrase()
    XCTAssertNil(modele.phraseRevelee)
  }

  // MARK: - Reprendre une sauvegarde

  func testEntrerLaPhraseRestaureEtPasseEnPlace() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "NEUF"), versionDistante: "4")
    let magasin = MagasinEnMemoire()
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais, magasin: magasin)
    await modele.sonder()
    await modele.entrerLaPhrase("  Abri Acier aigle album amande ancre arbre argile avion balcon banc barque ")
    let rejointes = await relais.phrasesRejointes
    XCTAssertEqual(
      rejointes,
      ["abri acier aigle album amande ancre arbre argile avion balcon banc barque"])
    XCTAssertEqual(modele.etape, .enPlace(version: "4", phraseConnue: true))
    XCTAssertEqual(modele.message, "10 clés sur 10 reprises.")
  }

  func testUnePhraseFausseEstDiteFausseEtLecranNeBougePas() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "NEUF"), versionDistante: "4")
    await relais.mettreRefus(true)
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    await modele.entrerLaPhrase("abri acier aigle album amande ancre arbre argile avion balcon banc barque")
    XCTAssertEqual(modele.etape, .aEntrer(version: "4"))
    XCTAssertEqual(modele.message, "Cette phrase n'ouvre pas la sauvegarde.")
  }

  func testUneSaisieTropCourteNeVaJamaisAuRelais() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "NEUF"), versionDistante: "4")
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    await modele.entrerLaPhrase("abri acier")
    let rejointes = await relais.phrasesRejointes
    XCTAssertTrue(rejointes.isEmpty)
  }

  // MARK: - Les appareils

  func testLesAppareilsSontRecollesEtOrdonnes() {
    let maintenant = Date(timeIntervalSince1970: 1_000_000)
    let vus = MatrixAppareilVu.fusionner(
      serveur: [
        .init(deviceID: "VIEUX", nom: "iPhone", derniereActiviteMS: 1_000_000_000 - 86_400_000),
        .init(deviceID: "MOI", nom: "Mac", derniereActiviteMS: 1_000_000_000),
        .init(deviceID: "RECENT", nom: "iPad", derniereActiviteMS: 1_000_000_000 - 960_000),
      ],
      crypto: [
        .init(deviceID: "MOI", verifieParSignature: true, estMoi: true),
        .init(deviceID: "RECENT", verifieParSignature: false),
      ],
      appareilCourant: "MOI")
    XCTAssertEqual(vus.map(\.deviceID), ["MOI", "RECENT", "VIEUX"])
    XCTAssertEqual(vus[0].etatFR, "cet appareil · vérifié")
    XCTAssertEqual(vus[1].etatFR, "non vérifié")
    // « On ne sait pas » n'est pas « non vérifié » : la machine crypto ignore
    // cet appareil, et l'écran ne doit pas prétendre l'avoir jugé.
    XCTAssertTrue(vus[2].etatCryptoInconnu)
    XCTAssertEqual(vus[2].etatFR, "état inconnu")
    XCTAssertEqual(vus[2].activiteFR(maintenant: maintenant), "il y a 1 j")
    XCTAssertEqual(vus[1].activiteFR(maintenant: maintenant), "il y a 16 min")
  }

  func testDeconnecterUnAppareilLeRetireDeLaListe() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "MOI"),
      appareils: [
        .init(deviceID: "MOI", estMoi: true), .init(deviceID: "VIEUX"),
      ])
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    let fait = await modele.deconnecter("VIEUX")
    XCTAssertTrue(fait)
    XCTAssertEqual(modele.appareils.map(\.deviceID), ["MOI"])
  }

  func testQuandLeRelaisVeutLeMotDePasseLecranLeDemandeAuLieuDechouer() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "MOI"),
      appareils: [.init(deviceID: "MOI", estMoi: true), .init(deviceID: "VIEUX")])
    await relais.mettreDeconnexion(.motDePasseRequis(session: "s1"))
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()

    let premier = await modele.deconnecter("VIEUX")
    XCTAssertFalse(premier, "le premier tour part sans mot de passe, exprès")
    XCTAssertEqual(modele.appareils.count, 2)

    let second = await modele.deconnecter("VIEUX", motDePasse: "secret")
    XCTAssertTrue(second)
    XCTAssertEqual(modele.appareils.map(\.deviceID), ["MOI"])
    let envoyees = await relais.deconnexions
    XCTAssertEqual(envoyees.map(\.1), [nil, "secret"], "le mot de passe ne part que sur demande")
  }

  func testOnNeSeDeconnectePasSoiMemeDepuisCetEcran() async {
    let relais = RelaisDePapier(
      etat: MatrixEtatChiffrement(actif: true, appareilID: "MOI"),
      appareils: [.init(deviceID: "MOI", estMoi: true)])
    let modele = ModeleChiffrement(compte: "@moi:x", service: relais)
    await modele.sonder()
    _ = await modele.deconnecter("MOI")
    let envoyees = await relais.deconnexions
    XCTAssertTrue(envoyees.isEmpty)
    XCTAssertEqual(modele.appareils.count, 1)
  }
}

extension RelaisDePapier {
  func mettreRefus(_ valeur: Bool) { refuseLaPhrase = valeur }
  func mettreDeconnexion(_ valeur: MatrixDeconnexionAppareil) { deconnexionRendue = valeur }
}
