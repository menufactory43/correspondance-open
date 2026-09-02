import XCTest

@testable import CorrespondanceCore
@testable import CorrespondanceMatrixClient

/// La couche « salon d'administration », éprouvée sur les **vraies** sorties de
/// Continuwuity 26.8.1, copiées de `docs/spike-un-clic/phase-1.md` et relevées
/// à nouveau en phase 4.
///
/// Le client Matrix n'avait jusqu'ici aucun faux réseau : ses tests portent sur
/// des fonctions pures (`MatrixURLBuildingTests`, `PusherTests`). On garde cet
/// esprit — l'analyse et la décision sont pures — et on ajoute le strict
/// minimum de faux transport là où il en fallait un : un salon `#admins` qui
/// répond ce que le vrai a répondu.

/// Un salon `#admins` de papier. Il rejoue une conversation : à chaque commande
/// postée, la réponse qu'on lui a donnée d'avance.
final class FauxSalonAdmin: MatrixAdminTransport, @unchecked Sendable {
  var alias: String?
  var salonResolu: String? = "!admins:unclic.local"
  var rejoints: [String] = ["!admins:unclic.local"]
  /// Ce que le bot répond, dans l'ordre des commandes reçues.
  var reponses: [String] = []
  /// Le bot répond-il ? Faux = un Relais muet, pour éprouver le délai borné.
  var botRepond = true
  private(set) var commandes: [String] = []
  private var journal: [MatrixAdminMessage] = []
  private var compteur = 0

  func resoudreAlias(_ alias: String) async throws -> String? {
    self.alias = alias
    return salonResolu
  }

  func salonsRejoints() async throws -> [String] { rejoints }

  func envoyerTexte(salon: String, corps: String) async throws -> String {
    compteur += 1
    let identifiant = "$cmd\(compteur)"
    commandes.append(corps)
    journal.insert(MatrixAdminMessage(eventID: identifiant, sender: "@essai:unclic.local", body: corps), at: 0)
    if botRepond, !reponses.isEmpty {
      let reponse = reponses.removeFirst()
      journal.insert(
        MatrixAdminMessage(eventID: "$rep\(compteur)", sender: "@conduit:unclic.local", body: reponse),
        at: 0)
    }
    return identifiant
  }

  func derniersMessages(salon: String, limite: Int) async throws -> [MatrixAdminMessage] {
    Array(journal.prefix(limite))
  }
}

private func salon(_ transport: FauxSalonAdmin) -> MatrixSalonAdmin {
  // Ni horloge ni sommeil réels : le test doit passer en millisecondes.
  MatrixSalonAdmin(transport: transport, serveur: "unclic.local", attendre: { _ in })
}

final class MatrixSalonAdminTests: XCTestCase {

  func testResoudLAliasDuSalonEtNeLeRedemandePas() async throws {
    let faux = FauxSalonAdmin()
    faux.reponses = ["Query completed in 7.375µs:\n\n```rs\n[]\n```", "un", "deux"]
    let couche = salon(faux)
    _ = try await couche.commande("!admin query users list-devices-metadata @cc:unclic.local")
    XCTAssertEqual(faux.alias, "#admins:unclic.local")
    _ = try await couche.commande("!admin users --help")
    // Résolu une fois par session. Le répertoire ne rend plus rien : si la
    // couche le redemandait, la troisième commande lèverait « salon
    // introuvable ». Elle passe, donc le salon était mémorisé.
    faux.salonResolu = nil
    let troisieme = try await couche.commande("!admin users list")
    XCTAssertEqual(troisieme, "deux")
    XCTAssertEqual(faux.commandes.count, 3)
  }

  /// « Je suis administrateur » = « je suis membre de #admins ». Vrai et faux
  /// sans deviner : c'est la ligne 1 de la matrice de la phase 1.
  func testAdministrateurCestEtreMembreDuSalonAdmins() async {
    let faux = FauxSalonAdmin()
    var verdict = await salon(faux).jeSuisAdministrateur()
    XCTAssertTrue(verdict)
    faux.rejoints = ["!autre:unclic.local"]
    verdict = await salon(faux).jeSuisAdministrateur()
    XCTAssertFalse(verdict)
    let sansSalon = FauxSalonAdmin()
    sansSalon.salonResolu = nil
    verdict = await salon(sansSalon).jeSuisAdministrateur()
    XCTAssertFalse(verdict)
  }

  /// La réponse du bot est celle qui suit **notre** message, pas la dernière du
  /// salon : deux commandes de suite ne doivent pas se voler leur réponse.
  func testLaReponseEstCelleDeNotreCommandeEtPasDuneAutre() {
    let messages = [
      MatrixAdminMessage(eventID: "$rep2", sender: "@conduit:unclic.local", body: "réponse à la 2e"),
      MatrixAdminMessage(eventID: "$cmd2", sender: "@essai:unclic.local", body: "seconde commande"),
      MatrixAdminMessage(eventID: "$rep1", sender: "@conduit:unclic.local", body: "réponse à la 1re"),
      MatrixAdminMessage(eventID: "$cmd1", sender: "@essai:unclic.local", body: "première commande"),
    ]
    XCTAssertEqual(
      MatrixSalonAdmin.reponse(dans: messages, apres: "$cmd1", de: "@conduit:unclic.local"),
      "réponse à la 1re")
    XCTAssertEqual(
      MatrixSalonAdmin.reponse(dans: messages, apres: "$cmd2", de: "@conduit:unclic.local"),
      "réponse à la 2e")
    // Notre event n'est pas dans la fenêtre : on n'invente rien.
    XCTAssertNil(
      MatrixSalonAdmin.reponse(dans: messages, apres: "$absent", de: "@conduit:unclic.local"))
  }

  /// Un Relais muet ne fige pas l'appelant : il lève, en le disant.
  func testUnRelaisMuetLeveAuLieuDAttendreIndefiniment() async {
    let faux = FauxSalonAdmin()
    faux.botRepond = false
    // L'horloge avance de dix secondes à chaque pause : deux tours et c'est fini.
    let horloge = Horloge()
    let couche = MatrixSalonAdmin(
      transport: faux, serveur: "unclic.local",
      attendre: { _ in horloge.avancer(10) }, maintenant: { horloge.maintenant })
    do {
      _ = try await couche.commande("!admin users list")
      XCTFail("un Relais muet devrait lever")
    } catch {
      XCTAssertEqual(
        error as? MatrixSalonAdmin.Echec, .botMuet(commande: "!admin users list"))
    }
  }

  /// Le refus du bot, tel qu'il l'écrit vraiment (relevé le 2 sept. 2026).
  func testUnRefusDuBotEstUneErreurEtPasUneReponse() async {
    let faux = FauxSalonAdmin()
    faux.reponses = ["Command failed with error:\n```\nUsername is not available.\n```"]
    do {
      _ = try await salon(faux).commande("!admin users create cc secret")
      XCTFail("un refus devrait lever")
    } catch {
      XCTAssertEqual(
        error as? MatrixSalonAdmin.Echec, .commandeRefusee("Username is not available."))
    }
    XCTAssertTrue(MatrixAdminCommandes.compteDejaLa("Username is not available."))
    XCTAssertFalse(MatrixAdminCommandes.compteDejaLa("The provided user does not exist."))
  }

  /// Les commandes, mot pour mot — c'est le contrat avec Continuwuity, et une
  /// faute de frappe ici ne se verrait qu'en production.
  func testLesCommandesSontEcritesMotPourMot() {
    XCTAssertEqual(
      MatrixAdminCommandes.creer(userID: "@cc:unclic.local", motDePasse: "s3cr3t"),
      "!admin users create cc s3cr3t")
    XCTAssertEqual(
      MatrixAdminCommandes.reposerMotDePasse(userID: "@cc:unclic.local", motDePasse: "s3cr3t"),
      "!admin users reset-password cc s3cr3t")
    // **Sans `--logout`** : les sessions ouvertes survivent, comme le
    // `logout_devices: false` de Synapse. Un `--logout` ici tuerait l'agent qui
    // tourne sur une autre machine.
    XCTAssertFalse(
      MatrixAdminCommandes.reposerMotDePasse(userID: "@cc:x", motDePasse: "p").contains("--logout"))
    XCTAssertEqual(
      MatrixAdminCommandes.sessions(userID: "@cc:unclic.local"),
      "!admin query users list-devices-metadata @cc:unclic.local")
    XCTAssertEqual(MatrixAdminCommandes.localpart("@cc:unclic.local"), "cc")
    XCTAssertEqual(MatrixAdminCommandes.localpart("cc"), "cc")
  }

  /// `M_UNRECOGNIZED` est le signal de bascule, et rien d'autre ne l'est : un
  /// 403 ou un 500 ne doivent pas faire croire à un Continuwuity.
  func testSeulUneRouteInconnueFaitBasculerSurLeSalonAdmin() {
    XCTAssertTrue(
      MatrixClient.estUneRouteInconnue(
        MatrixError.http(status: 404, errcode: "M_UNRECOGNIZED", message: "not found :(")))
    XCTAssertTrue(MatrixClient.estUneRouteInconnue(MatrixError.http(status: 404, errcode: nil, message: nil)))
    XCTAssertFalse(
      MatrixClient.estUneRouteInconnue(
        MatrixError.http(status: 403, errcode: "M_FORBIDDEN", message: "nope")))
    XCTAssertFalse(MatrixClient.estUneRouteInconnue(MatrixError.transport("réseau coupé")))
  }

  /// `makeRoomAdmin` n'a pas d'équivalent : le message le dit en français, et
  /// nomme l'opération. C'est ce que l'écran affiche.
  func testMakeRoomAdminDitFranchementQueCeNestPasDisponible() {
    let erreur = MatrixError.administrationIndisponible("donner le pouvoir dans un salon (make_room_admin)")
    let texte = erreur.errorDescription ?? ""
    XCTAssertTrue(texte.contains("Pas disponible sur ce Relais"), texte)
    XCTAssertTrue(texte.contains("make_room_admin"), texte)
  }
}

/// Une horloge de papier, pour éprouver un délai borné sans attendre.
private final class Horloge: @unchecked Sendable {
  private(set) var maintenant = Date(timeIntervalSince1970: 1_788_000_000)
  func avancer(_ secondes: TimeInterval) { maintenant = maintenant.addingTimeInterval(secondes) }
}

// MARK: - Le `Debug` Rust de list-devices-metadata

final class MatrixSessionsRustTests: XCTestCase {

  /// La sortie **compacte**, copiée mot pour mot de `docs/spike-un-clic/phase-1.md` § 3.
  private let compacte = """
    Query completed in 7.375µs:

    ```rs
    [
        Device {
            device_id: "yvWPihBJlI",
            display_name: Some("cc sur le Mac du spike"),
            last_seen_ip: Some("127.0.0.1"),
            last_seen_ts: Some(2026-09-01T22:49:06.935),
        },
    ]
    ```
    """

  /// La sortie **repliée**, relevée le 2 septembre 2026 sur le même Relais.
  /// Rust replie son `Debug` dès que la ligne s'allonge : les deux formes
  /// existent pour de vrai, et l'analyseur doit lire les deux. C'est
  /// exactement le genre de détail qui ne se voit qu'à l'exécution.
  private let repliee = """
    Query completed in 1.033416ms:

    ```rs
    [
        Device {
            device_id: "rTrhsKJG4B",
            display_name: Some(
                "Correspondance agent · macmini-essai",
            ),
            last_seen_ip: Some(
                "127.0.0.1",
            ),
            last_seen_ts: Some(
                2026-09-02T08:16:50.153,
            ),
        },
    ]
    ```
    """

  func testLaSortieCompacteDeLaPhase1SeLit() {
    let sessions = MatrixSessionsRust.analyser(compacte)
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.deviceID, "yvWPihBJlI")
    XCTAssertEqual(sessions.first?.displayName, "cc sur le Mac du spike")
    XCTAssertEqual(
      sessions.first?.lastSeen,
      MatrixSessionsRust.lireHorodatage("2026-09-01T22:49:06.935"))
  }

  func testLaSortieRepliéeSeLitPareil() {
    let sessions = MatrixSessionsRust.analyser(repliee)
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.deviceID, "rTrhsKJG4B")
    XCTAssertEqual(sessions.first?.displayName, "Correspondance agent · macmini-essai")
    XCTAssertNotNil(sessions.first?.lastSeen)
  }

  /// `[]` — le compte existe, aucune session ouverte. C'est la réponse qu'on
  /// obtient juste après `!admin users create`.
  func testAucuneSessionRendUneListeVide() {
    XCTAssertTrue(
      MatrixSessionsRust.analyser("Query completed in 294.375µs:\n\n```rs\n[]\n```").isEmpty)
    XCTAssertTrue(MatrixSessionsRust.analyser("").isEmpty)
  }

  func testPlusieursSessionsEtUnNomAbsent() {
    let texte = """
      ```rs
      [
          Device {
              device_id: "CvTKwcDn8W",
              display_name: Some("relais-install"),
              last_seen_ts: Some(2026-09-01T23:55:00.000),
          },
          Device {
              device_id: "qmVCsB988W",
              display_name: None,
              last_seen_ip: Some("127.0.0.1"),
              last_seen_ts: None,
          },
      ]
      ```
      """
    let sessions = MatrixSessionsRust.analyser(texte)
    XCTAssertEqual(sessions.map(\.deviceID), ["CvTKwcDn8W", "qmVCsB988W"])
    XCTAssertEqual(sessions[0].displayName, "relais-install")
    XCTAssertNil(sessions[1].displayName)
    XCTAssertNil(sessions[1].lastSeen)
  }

  /// **L'horodatage est en UTC**, et c'est mesuré, pas supposé : le Relais a
  /// écrit `2026-09-02T08:16:50.153` pour une connexion faite à 10:16:50+02:00.
  /// Le lire en heure locale ferait vieillir une session de deux heures, et la
  /// garde du second cc laisserait démarrer un doublon.
  func testLHorodatageEstLuEnUTC() throws {
    let date = try XCTUnwrap(MatrixSessionsRust.lireHorodatage("2026-09-02T08:16:50.153"))
    var formatteur = DateFormatter()
    formatteur.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatteur.timeZone = TimeZone(identifier: "UTC")
    XCTAssertEqual(formatteur.string(from: date), "2026-09-02T08:16:50")
    formatteur = DateFormatter()
    formatteur.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatteur.timeZone = TimeZone(secondsFromGMT: 2 * 3600)
    XCTAssertEqual(formatteur.string(from: date), "2026-09-02T10:16:50")
  }

  /// **Le point qui compte** : ce que l'analyseur rend alimente la garde du
  /// second cc telle qu'elle existe, fenêtre de quinze minutes comprise.
  func testLeResultatAlimenteLaGardeDuSecondCC() throws {
    let texte = """
      ```rs
      [
          Device {
              device_id: "rTrhsKJG4B",
              display_name: Some(
                  "Correspondance agent · umbrel",
              ),
              last_seen_ts: Some(
                  2026-09-02T08:16:50.153,
              ),
          },
      ]
      ```
      """
    let sessions = MatrixSessionsRust.analyser(texte)
    let vue = try XCTUnwrap(sessions.first?.lastSeen)

    // Vue il y a trois minutes, depuis une AUTRE machine : la garde refuse et
    // nomme la session.
    XCTAssertEqual(
      AgentSessions.elsewhere(sessions, here: "macmini", now: vue.addingTimeInterval(180)),
      "umbrel (vu il y a 3 min)")
    // La même session, mais c'est la nôtre : rien à refuser.
    XCTAssertNil(AgentSessions.elsewhere(sessions, here: "umbrel", now: vue.addingTimeInterval(180)))
    // Au-delà de quinze minutes, c'est un cadavre : on laisse démarrer.
    XCTAssertNil(
      AgentSessions.elsewhere(
        sessions, here: "macmini", now: vue.addingTimeInterval(AgentSessions.silenceMax + 1)))
  }
}
