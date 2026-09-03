import Foundation
import Observation
import CorrespondanceMatrixClient

/// Ce que les deux écrans du chiffrement ont besoin de savoir faire.
///
/// Un protocole, et non `MatrixBridgeService` directement, pour une raison
/// précise : ces écrans décident quoi montrer d'après des faits distants (une
/// sauvegarde existe-t-elle ? cet appareil est-il vérifié ?) et cette décision
/// doit être éprouvée sans Relais. Le service réel s'y conforme dans
/// `MatrixBridgeService+ModeleChiffrement.swift`.
public protocol ChiffrementDuCompte: Sendable {
  func etat() async -> MatrixEtatChiffrement
  func versionDeSauvegarde() async -> String?
  func appareils() async -> [MatrixAppareilVu]
  func creerSauvegarde(phrase: String, remplacer: Bool) async throws -> Int
  func rejoindreSauvegarde(phrase: String) async throws -> MatrixImportDeCles
  func deposerLesSignatures(phrase: String) async throws
  func amorcerLesSignatures(motDePasse: String?) async throws
  func deconnecterAppareil(_ deviceID: String, motDePasse: String?) async throws
    -> MatrixDeconnexionAppareil
}

/// Où la phrase est gardée sur **cet** appareil, pour que « Revoir la phrase »
/// veuille dire quelque chose.
///
/// Sans ce magasin, « Revoir » serait un mensonge : la phrase n'existe nulle
/// part ailleurs, et le Relais ne la connaît pas — c'est tout l'intérêt. La
/// garder ici est un choix, et il coûte : quelqu'un qui ouvre ce Mac déverrouillé
/// peut la lire. Le compromis se dit à l'écran (« gardée sur cet appareil »)
/// plutôt que d'être caché.
public protocol MagasinDePhrase: Sendable {
  func lire(compte: String) -> String?
  func ecrire(_ phrase: String, compte: String)
  func effacer(compte: String)
}

/// Le magasin qui ne garde rien : « Revoir » n'est alors pas proposé, seulement
/// « Changer ». C'est le défaut des tests, et le repli d'une plateforme sans
/// trousseau.
public struct MagasinDePhraseVide: MagasinDePhrase {
  public init() {}
  public func lire(compte: String) -> String? { nil }
  public func ecrire(_ phrase: String, compte: String) {}
  public func effacer(compte: String) {}
}

/// L'écran de la phrase de récupération, réduit à ses états.
///
/// C'est ici que tient la seule vraie question de cet écran : **que montrer à
/// la première connexion d'un appareil ?** Trois réponses, et elles ne se
/// devinent pas d'un seul fait :
///
/// - aucune sauvegarde sur le Relais → on en propose une, on tire la phrase ;
/// - une sauvegarde existe, et cet appareil ne l'a pas rejointe → « Entrer la
///   phrase » : l'appareil est neuf, l'historique d'avant sa naissance est
///   derrière ces douze mots ;
/// - une sauvegarde existe et cet appareil la connaît → rien à faire, sinon
///   revoir ou changer.
public enum EtapeDeLaPhrase: Sendable, Equatable {
  /// Pas encore sondé.
  case inconnue
  /// Le chiffrement n'est pas dans ce binaire, ou la session n'est pas ouverte.
  case indisponible(raison: String)
  /// Aucune sauvegarde n'existe : on propose d'en créer une.
  case aProposer
  /// La phrase vient d'être tirée. **Elle n'est montrée qu'une fois** — tant
  /// que « je l'ai notée » n'est pas cliqué, on reste ici.
  case aNoter(phrase: String)
  /// Une sauvegarde existe, cet appareil ne l'a pas rejointe.
  case aEntrer(version: String)
  /// Tout est en place.
  case enPlace(version: String, phraseConnue: Bool)

  public var titreFR: String {
    switch self {
    case .inconnue: "Phrase de récupération"
    case .indisponible: "Phrase de récupération"
    case .aProposer: "Note ta phrase de récupération"
    case .aNoter: "Voici ta phrase, note-la maintenant"
    case .aEntrer: "Entre ta phrase de récupération"
    case .enPlace: "Phrase de récupération"
    }
  }

  public var expliqueFR: String {
    switch self {
    case .inconnue:
      "…"
    case let .indisponible(raison):
      raison
    case .aProposer:
      "Douze mots à recopier sur un papier. C’est le seul moyen de retrouver tes conversations "
        + "sur un nouvel appareil. Personne d’autre ne les connaît."
    case .aNoter:
      "Recopie-les maintenant, ils ne seront pas remontrés."
    case .aEntrer:
      "Une sauvegarde existe déjà. Entre tes douze mots pour retrouver l’historique sur cet appareil."
    case let .enPlace(version, phraseConnue):
      "Sauvegarde \(version) en place."
        + (phraseConnue
          ? " La phrase est gardée ici, tu peux la revoir."
          : " La phrase n’est pas gardée ici. Tu peux en créer une nouvelle.")
    }
  }
}

/// Le modèle des deux écrans : la phrase, et les appareils.
///
/// `@MainActor` parce qu'il porte l'état d'un écran, pas parce qu'il fait du
/// réseau : tout appel distant part sur l'acteur du service et revient ici.
@MainActor
@Observable
public final class ModeleChiffrement {

  public private(set) var etape: EtapeDeLaPhrase = .inconnue
  public private(set) var appareils: [MatrixAppareilVu] = []
  public private(set) var etat = MatrixEtatChiffrement()
  public private(set) var occupe = false
  /// Le dernier message à afficher — succès comme échec. Une seule ligne :
  /// deux zones de message sur un écran de réglages, personne ne les lit.
  public private(set) var message: String?
  /// La phrase révélée par « Revoir », effacée dès qu'on quitte l'écran.
  public private(set) var phraseRevelee: String?

  private let compte: String
  private let service: any ChiffrementDuCompte
  private let magasin: any MagasinDePhrase

  public init(
    compte: String, service: any ChiffrementDuCompte,
    magasin: any MagasinDePhrase = MagasinDePhraseVide()
  ) {
    self.compte = compte
    self.service = service
    self.magasin = magasin
  }

  // MARK: - Sonder

  /// Le seul point d'entrée de l'écran. Il ne devine pas : il demande au
  /// Relais s'il héberge une sauvegarde, et à la machine crypto si cet
  /// appareil la connaît.
  public func sonder() async {
    // Une phrase tirée et pas encore notée survit à un `sonder()` : sans cette
    // garde, un rafraîchissement de l'écran ferait disparaître douze mots que
    // personne n'a recopiés, et la sauvegarde qui les attend serait perdue.
    if case .aNoter = etape { return }
    occupe = true
    defer { occupe = false }
    etat = await service.etat()
    guard etat.actif else {
      etape = .indisponible(
        raison: MatrixChiffrement.disponible
          ? "Pas encore connecté."
          : "Le chiffrement n’est pas disponible dans cette version.")
      appareils = []
      return
    }
    appareils = await service.appareils()
    let distante = await service.versionDeSauvegarde()
    switch (distante, etat.sauvegardeVersion) {
    case (nil, _):
      etape = .aProposer
    case let (version?, locale) where locale == version:
      etape = .enPlace(version: version, phraseConnue: magasin.lire(compte: compte) != nil)
    case let (version?, _):
      etape = .aEntrer(version: version)
    }
  }

  // MARK: - Poser une phrase

  /// Tire une phrase et la montre. Rien n'est encore envoyé au Relais : la
  /// sauvegarde n'est créée qu'à « je l'ai notée ». Une sauvegarde créée avant
  /// que la phrase soit lue serait une sauvegarde que personne ne peut ouvrir.
  public func proposerUnePhrase() {
    etape = .aNoter(phrase: PhraseDeRecuperation.engendrer())
    message = nil
  }

  /// « Je l'ai notée » : c'est **ici** que la sauvegarde naît, que les clés y
  /// partent, et que les clés de signature entrent au coffre.
  public func confirmerLaPhrase() async {
    guard case let .aNoter(phrase) = etape else { return }
    occupe = true
    defer { occupe = false }
    do {
      // Les signatures croisées d'abord : sans elles, le coffre n'a rien à
      // porter, et l'appareil suivant restera « non vérifié » malgré la phrase.
      try? await service.amorcerLesSignatures(motDePasse: nil)
      let poussees = try await service.creerSauvegarde(phrase: phrase, remplacer: true)
      try await service.deposerLesSignatures(phrase: phrase)
      magasin.ecrire(phrase, compte: compte)
      message = "Sauvegarde créée · \(poussees) clé\(poussees > 1 ? "s" : "") envoyée\(poussees > 1 ? "s" : "")."
      await sonderApresChangement()
    } catch {
      message = "La sauvegarde n'a pas pu être créée : \(error.localizedDescription)"
    }
  }

  /// « Changer la phrase » : la sauvegarde est remplacée, l'ancienne retirée.
  /// C'est la même mécanique que la création, avec le remplacement assumé —
  /// Continuwuity refuse d'écrire ailleurs que dans la dernière version
  /// (piège de la phase 5), donc remplacer veut dire retirer toutes les autres.
  public func changerLaPhrase() {
    proposerUnePhrase()
    message = "L’ancienne phrase ne servira plus une fois celle-ci notée."
  }

  /// « Revoir la phrase » : seulement si cet appareil la garde encore.
  public func revoirLaPhrase() {
    guard let phrase = magasin.lire(compte: compte) else {
      message = "Cette phrase n'est pas gardée sur cet appareil."
      return
    }
    phraseRevelee = phrase
  }

  public func cacherLaPhrase() { phraseRevelee = nil }

  // MARK: - Reprendre une sauvegarde

  /// L'appareil neuf. On refuse une saisie qui n'a pas la forme d'une phrase
  /// **avant** tout aller-retour : le Relais n'a pas à voir une frappe en cours.
  public func entrerLaPhrase(_ saisie: String) async {
    let phrase = PhraseDeRecuperation.normaliser(saisie)
    guard PhraseDeRecuperation.semblePlausible(phrase) else {
      message = "Une phrase de récupération fait douze mots séparés par des espaces."
      return
    }
    occupe = true
    defer { occupe = false }
    do {
      let import_ = try await service.rejoindreSauvegarde(phrase: phrase)
      magasin.ecrire(phrase, compte: compte)
      message = "\(import_.importees) clé\(import_.importees > 1 ? "s" : "") sur \(import_.total) reprise\(import_.importees > 1 ? "s" : "")."
      await sonderApresChangement()
    } catch {
      message = "Cette phrase n'ouvre pas la sauvegarde."
    }
  }

  // MARK: - Les appareils

  public func rafraichirLesAppareils() async {
    occupe = true
    defer { occupe = false }
    appareils = await service.appareils()
  }

  /// « Déconnecter cet appareil ». Deux tours : sans mot de passe d'abord,
  /// parce qu'un Relais peut ne rien demander ; l'écran redemande ensuite.
  /// Rend `true` quand c'est fait, `false` quand il faut le mot de passe.
  @discardableResult
  public func deconnecter(_ deviceID: String, motDePasse: String? = nil) async -> Bool {
    guard deviceID != etat.appareilID else {
      message = "C’est cet appareil. Pour le déconnecter, passe par « Déconnecter » plus bas."
      return true
    }
    occupe = true
    defer { occupe = false }
    do {
      switch try await service.deconnecterAppareil(deviceID, motDePasse: motDePasse) {
      case .faite:
        appareils = await service.appareils()
        message = "\(deviceID) est déconnecté."
        return true
      case .motDePasseRequis:
        message = "Le Relais demande le mot de passe du compte pour déconnecter \(deviceID)."
        return false
      }
    } catch {
      message = "Déconnexion refusée : \(error.localizedDescription)"
      return true
    }
  }

  public func oublierLeMessage() { message = nil }

  /// Après une écriture, on resonde — mais sans la garde de `aNoter`, qui
  /// vient justement d'être franchie.
  private func sonderApresChangement() async {
    etape = .inconnue
    let occupeAvant = occupe
    occupe = false
    await sonder()
    occupe = occupeAvant
  }
}
