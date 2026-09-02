import Foundation

/// La couche « salon d'administration » : ce que l'app fait chez Synapse par
/// `_synapse/admin`, faite chez Continuwuity par des **messages dans `#admins`**.
///
/// Continuwuity n'a pas d'API HTTP d'administration — deux routes en tout, ni
/// création de compte, ni sessions, ni `make_room_admin` (matrice de la phase 1,
/// `docs/spike-un-clic/phase-1.md` § 3). Tout passe par une commande postée dans
/// `#admins:<serveur>`, à laquelle `@conduit:<serveur>` répond dans le même
/// salon. Ce fichier est la traduction Swift de `infra/relais-spike/salon-admin.py`.
///
/// **L'appelant ne change pas.** `MatrixBridgeService` continue d'appeler
/// `isServerAdmin`, `provisionUser`, `userDevices` ; c'est le client qui sait
/// sur quel Relais il parle.

// MARK: - Ce que la couche demande au Relais

/// Un message du salon d'administration.
public struct MatrixAdminMessage: Sendable, Equatable {
  public var eventID: String
  public var sender: String
  public var body: String
  public init(eventID: String, sender: String, body: String) {
    self.eventID = eventID
    self.sender = sender
    self.body = body
  }
}

/// Le strict nécessaire pour parler à `#admins`. C'est un protocole et non des
/// appels directs pour une raison unique : un test doit pouvoir répondre à la
/// place du réseau, avec les **vraies** sorties relevées en phase 1.
public protocol MatrixAdminTransport: Sendable {
  /// `#admins:<serveur>` → `!…` , ou `nil` si l'alias n'existe pas.
  func resoudreAlias(_ alias: String) async throws -> String?
  /// `GET /joined_rooms`.
  func salonsRejoints() async throws -> [String]
  /// Poste la commande. Rend l'`event_id`.
  func envoyerTexte(salon: String, corps: String) async throws -> String
  /// Les messages du salon, **du plus récent au plus ancien**.
  func derniersMessages(salon: String, limite: Int) async throws -> [MatrixAdminMessage]
}

// MARK: - Envoyer une commande, attendre la réponse du bot

/// Poste une commande dans `#admins` et rend la réponse du bot du serveur.
///
/// Le délai est **borné** : un Relais muet ne doit pas figer l'écran qui a
/// appelé. On relit l'historique du salon plutôt que d'ouvrir un second `/sync`,
/// pour ne pas doubler la boucle de synchronisation de l'app.
public actor MatrixSalonAdmin {
  /// Au-delà, on renonce et on le dit. Mesuré : une commande d'administration
  /// répond en quelques millisecondes ; vingt secondes, c'est une panne.
  public static let delaiMax: TimeInterval = 20
  /// Entre deux relectures de l'historique.
  public static let pause: TimeInterval = 0.4

  public enum Echec: LocalizedError, Equatable {
    /// Ce Relais n'a pas de salon d'administration : ce n'est ni un Synapse ni
    /// un Continuwuity dont nous sommes administrateur.
    case salonIntrouvable(serveur: String)
    /// Le bot n'a rien dit dans le délai.
    case botMuet(commande: String)
    /// Le bot a répondu, mais par un refus.
    case commandeRefusee(String)

    public var errorDescription: String? {
      switch self {
      case .salonIntrouvable(let serveur):
        "le salon d'administration #admins:\(serveur) est introuvable — ce compte n'est "
          + "probablement pas administrateur de ce Relais"
      case .botMuet(let commande):
        "le Relais n'a pas répondu à « \(commande) » en \(Int(MatrixSalonAdmin.delaiMax)) s"
      case .commandeRefusee(let detail):
        "le Relais a refusé la commande : \(detail)"
      }
    }
  }

  private let transport: any MatrixAdminTransport
  private let serveur: String
  private let attendre: @Sendable (TimeInterval) async -> Void
  private let maintenant: @Sendable () -> Date
  private var salon: String?

  public init(
    transport: any MatrixAdminTransport,
    serveur: String,
    attendre: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
    maintenant: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.serveur = serveur
    self.attendre = attendre
    self.maintenant = maintenant
  }

  /// L'alias tel qu'on le résout. Public pour que le test le dise mot à mot.
  public static func alias(serveur: String) -> String { "#admins:\(serveur)" }

  /// Le bot du serveur. Continuwuity a gardé le nom de son ancêtre Conduit.
  public static func bot(serveur: String) -> String { "@conduit:\(serveur)" }

  /// Le salon d'administration, résolu une fois par session.
  public func salonAdmin() async throws -> String {
    if let salon { return salon }
    // `try?` aplatit déjà le double optionnel : « pas d'alias » et « appel en
    // erreur » se disent de la même façon, et c'est bien ce qu'on veut ici.
    guard let resolu = try? await transport.resoudreAlias(Self.alias(serveur: serveur)),
          !resolu.isEmpty
    else { throw Echec.salonIntrouvable(serveur: serveur) }
    salon = resolu
    return resolu
  }

  /// Suis-je membre du salon d'administration ? C'est **la** définition de
  /// « administrateur » chez Continuwuity : le premier compte enregistré y est
  /// mis d'office, et personne d'autre n'y entre.
  public func jeSuisAdministrateur() async -> Bool {
    guard let salon = try? await salonAdmin() else { return false }
    guard let rejoints = try? await transport.salonsRejoints() else { return false }
    return rejoints.contains(salon)
  }

  /// Envoie une commande et rend la réponse du bot, ou lève.
  @discardableResult
  public func commande(_ texte: String) async throws -> String {
    let salon = try await salonAdmin()
    let envoi = try await transport.envoyerTexte(salon: salon, corps: texte)
    let bot = Self.bot(serveur: serveur)
    let fin = maintenant().addingTimeInterval(Self.delaiMax)
    while maintenant() < fin {
      let messages = (try? await transport.derniersMessages(salon: salon, limite: 20)) ?? []
      if let reponse = Self.reponse(dans: messages, apres: envoi, de: bot) {
        if let refus = Self.refus(dans: reponse) { throw Echec.commandeRefusee(refus) }
        return reponse
      }
      await attendre(Self.pause)
    }
    throw Echec.botMuet(commande: texte)
  }

  /// La réponse du bot dans un historique **du plus récent au plus ancien** :
  /// le plus ancien message du bot arrivé *après* le nôtre. Prendre le plus
  /// récent prendrait la réponse d'une commande suivante ; ne pas s'arrêter à
  /// notre propre event relirait l'historique et prendrait une vieille réponse
  /// — le défaut que `salon-admin.py` évitait déjà par un marqueur de `/sync`.
  public static func reponse(
    dans messages: [MatrixAdminMessage], apres envoi: String, de bot: String
  ) -> String? {
    var candidate: String?
    for message in messages {
      if message.eventID == envoi { return candidate }
      if message.sender == bot { candidate = message.body }
    }
    // Notre propre event n'est pas (ou plus) dans la fenêtre : on n'invente rien.
    return nil
  }

  /// « Command failed with error: » suivi d'un bloc de code — la forme d'un
  /// refus chez Continuwuity (« Username is not available. »).
  public static func refus(dans reponse: String) -> String? {
    guard reponse.contains("Command failed with error") else { return nil }
    let lignes = reponse.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0 != "```" && !$0.hasPrefix("Command failed") }
    return lignes.first ?? "sans détail"
  }
}

// MARK: - Les sessions, en `Debug` Rust

/// L'analyseur de `!admin query users list-devices-metadata`.
///
/// Continuwuity ne rend pas du JSON mais le `Debug` Rust de ses structures, dans
/// un bloc ```` ```rs ````. C'est le changement le plus laid de la matrice, et
/// il est ici seul, pur, et éprouvé sur les **deux** formes réellement observées :
/// compacte (phase 1) et repliée sur plusieurs lignes (phase 4) — Rust replie
/// dès que la ligne s'allonge.
public enum MatrixSessionsRust {

  /// `last_seen_ts` n'a pas de fuseau. Mesuré le 2 sept. 2026 : le Relais a
  /// écrit `2026-09-02T08:16:50.153` pour une connexion faite à 10:16:50+02:00.
  /// C'est de l'**UTC**. Le lire en heure locale ferait passer une session
  /// vivante pour vieille de deux heures, et la garde du second cc laisserait
  /// démarrer un doublon.
  public static let fuseau = TimeZone(identifier: "UTC")!

  public static func analyser(_ texte: String) -> [MatrixClient.UserDevice] {
    let plat = aplatir(texte)
    var sessions: [MatrixClient.UserDevice] = []
    for bloc in plat.components(separatedBy: "Device {").dropFirst() {
      let corps = bloc.components(separatedBy: "}").first ?? bloc
      guard let identifiant = chaine(champ: "device_id", dans: corps) else { continue }
      sessions.append(
        MatrixClient.UserDevice(
          deviceID: identifiant,
          displayName: chaine(champ: "display_name", dans: corps),
          lastSeen: date(champ: "last_seen_ts", dans: corps)
        )
      )
    }
    return sessions
  }

  /// Replie le `Debug` multi-lignes en une ligne : `Some(\n  "x",\n)` devient
  /// `Some("x")`. Après ça, les deux formes de Rust se lisent pareil.
  static func aplatir(_ texte: String) -> String {
    var plat = texte.replacingOccurrences(of: "\n", with: " ")
    plat = plat.replacingOccurrences(
      of: " +", with: " ", options: .regularExpression)
    plat = plat.replacingOccurrences(of: "Some( ", with: "Some(")
    plat = plat.replacingOccurrences(
      of: ", \\)", with: ")", options: .regularExpression)
    plat = plat.replacingOccurrences(of: " )", with: ")")
    return plat
  }

  /// `champ: "valeur"` ou `champ: Some("valeur")` ; `None` rend `nil`.
  static func chaine(champ: String, dans corps: String) -> String? {
    for motif in ["\(champ): Some\\(\"((?:[^\"\\\\]|\\\\.)*)\"\\)", "\(champ): \"((?:[^\"\\\\]|\\\\.)*)\""] {
      if let valeur = premiereCapture(motif, dans: corps) {
        return valeur.replacingOccurrences(of: "\\\"", with: "\"")
          .replacingOccurrences(of: "\\\\", with: "\\")
      }
    }
    return nil
  }

  /// `champ: Some(2026-09-01T22:49:06.935)` — pas de guillemets, pas de fuseau.
  static func date(champ: String, dans corps: String) -> Date? {
    guard let brut = premiereCapture("\(champ): Some\\(([0-9T:.\\-]+)\\)", dans: corps) else { return nil }
    return lireHorodatage(brut)
  }

  public static func lireHorodatage(_ brut: String) -> Date? {
    var composants = DateComponents()
    let parties = brut.split(separator: "T")
    guard parties.count == 2 else { return nil }
    let jour = parties[0].split(separator: "-")
    let heure = parties[1].split(separator: ":")
    guard jour.count == 3, heure.count == 3 else { return nil }
    composants.year = Int(jour[0])
    composants.month = Int(jour[1])
    composants.day = Int(jour[2])
    composants.hour = Int(heure[0])
    composants.minute = Int(heure[1])
    let secondes = heure[2].split(separator: ".")
    composants.second = Int(secondes[0])
    if secondes.count > 1, let millis = Double("0.\(secondes[1])") {
      composants.nanosecond = Int(millis * 1_000_000_000)
    }
    var calendrier = Calendar(identifier: .gregorian)
    calendrier.timeZone = fuseau
    return calendrier.date(from: composants)
  }

  static func premiereCapture(_ motif: String, dans texte: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: motif) else { return nil }
    let plage = NSRange(texte.startIndex..., in: texte)
    guard let trouve = regex.firstMatch(in: texte, range: plage), trouve.numberOfRanges > 1,
          let capture = Range(trouve.range(at: 1), in: texte)
    else { return nil }
    return String(texte[capture])
  }
}

// MARK: - Les commandes, écrites une fois

/// Les commandes `!admin` que l'app envoie, et la lecture de leurs réponses.
/// Pures : c'est ce qui rend la couche éprouvable sans Relais.
public enum MatrixAdminCommandes {

  /// Le localpart d'un MXID : `@cc:unclic.local` → `cc`.
  public static func localpart(_ userID: String) -> String {
    let sans = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(sans.split(separator: ":").first ?? "")
  }

  /// `!admin users create <nom> <mot de passe>` — le mot de passe est bien
  /// choisi par l'appelant (vérifié : `create --help` l'accepte en second
  /// argument, et sans lui le serveur en tire un que nous ne connaîtrions pas).
  public static func creer(userID: String, motDePasse: String) -> String {
    "!admin users create \(localpart(userID)) \(motDePasse)"
  }

  /// `!admin users reset-password <nom> <mot de passe>` — **sans `--logout`** :
  /// les sessions ouvertes survivent, exact équivalent du `logout_devices: false`
  /// de Synapse. Sans cette précaution, poser un mot de passe depuis ce Mac
  /// tuerait l'agent qui tourne sur une autre machine.
  public static func reposerMotDePasse(userID: String, motDePasse: String) -> String {
    "!admin users reset-password \(localpart(userID)) \(motDePasse)"
  }

  public static func sessions(userID: String) -> String {
    "!admin query users list-devices-metadata \(userID)"
  }

  /// « Username is not available. » n'est pas une panne : le compte est déjà
  /// là, il faut lui reposer un mot de passe au lieu de le créer.
  public static func compteDejaLa(_ detail: String) -> Bool {
    detail.localizedCaseInsensitiveContains("not available")
      || detail.localizedCaseInsensitiveContains("already exists")
  }
}
