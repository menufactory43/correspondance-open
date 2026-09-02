import CorrespondanceCore
import CryptoKit
import Foundation
import OSLog

/// Poser un Relais **depuis l'app**, sur ce Mac, sans terminal.
///
/// L'installeur reste un script — le même que celui qu'on colle sur un NUC, à
/// la ligne près : deux installeurs qui divergent, c'est un des deux qui n'est
/// jamais éprouvé. Ce qui change, c'est qu'on le lance en `--json`, où chaque
/// étape est une ligne lisible par programme, et où la dernière ligne porte le
/// code d'appairage. L'app le colle elle-même : rien à recopier.
///
/// Ce fichier tient trois choses, séparées exprès parce que les deux premières
/// sont pures et donc éprouvables sans réseau ni processus :
/// 1. `RelaisEvenement` — l'analyse d'une ligne du flux ;
/// 2. `RelaisSommes` — la vérification du sha256 contre le `SHA256SUMS` publié ;
/// 3. `RelaisInstallateur` — le téléchargement, le processus enfant, l'appairage.

// MARK: - 1. Le flux

/// Une étape de l'installeur, telle qu'elle arrive.
struct RelaisEtape: Equatable, Sendable {
  enum Etat: String, Sendable, Equatable {
    case debut, ok, erreur
  }

  var etape: String
  var etat: Etat
  var detail: String

  /// Ce qu'on montre dans la liste. L'installeur nomme ses étapes en un mot
  /// (`binaires`, `services`, `preuve`) : l'app les traduit une fois ici,
  /// plutôt que de laisser un identifiant à l'écran.
  var libelleFR: String {
    switch etape {
    case "prerequis": "Vérification de la machine"
    case "binaires": "Téléchargement des binaires"
    case "secrets": "Secrets du Relais"
    case "configuration": "Configuration"
    case "services": "Démarrage des services"
    case "attente": "Attente du Relais"
    case "compte": "Compte propriétaire"
    case "ponts": "Les quatre réseaux"
    case "preuve": "Preuve de connexion"
    case "appairage": "Appairage"
    default: etape
    }
  }
}

/// Ce qu'une ligne du flux peut être.
enum RelaisEvenement: Equatable, Sendable {
  case etape(RelaisEtape)
  /// La dernière ligne : le code que l'app colle, et les six mots qui le
  /// vérifient.
  case appairage(code: String, mots: [String])
}

enum RelaisFlux {
  /// Analyse **une** ligne. Rend `nil` pour tout ce qui n'est pas un objet du
  /// protocole — et il y en a : un `curl` qui écrit sur stderr, une trace de
  /// `cargo`, une ligne vide. Une ligne illisible ne doit jamais faire échouer
  /// l'installation ; elle doit seulement ne rien afficher.
  static func analyser(ligne: String) -> RelaisEvenement? {
    let taille = ligne.trimmingCharacters(in: .whitespacesAndNewlines)
    guard taille.hasPrefix("{"), let donnees = taille.data(using: .utf8) else { return nil }
    guard let objet = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any],
          let etape = objet["etape"] as? String
    else { return nil }
    // L'appairage se reconnaît à son `code`, pas à son nom : c'est le contenu
    // qui décide, sinon une étape nommée « appairage » sans code serait prise
    // pour la fin et l'app se croirait prête.
    if let code = objet["code"] as? String {
      return .appairage(code: code, mots: objet["mots"] as? [String] ?? [])
    }
    guard let etat = RelaisEtape.Etat(rawValue: objet["etat"] as? String ?? "") else { return nil }
    return .etape(RelaisEtape(etape: etape, etat: etat, detail: objet["detail"] as? String ?? ""))
  }

  /// Fusionne une étape dans la liste affichée : une étape qui passe de
  /// `debut` à `ok` **remplace** la sienne au lieu de s'ajouter — sinon la
  /// liste double à chaque étape et personne ne sait où on en est.
  static func fusionner(_ liste: [RelaisEtape], avec nouvelle: RelaisEtape) -> [RelaisEtape] {
    var sortie = liste
    if let index = sortie.lastIndex(where: { $0.etape == nouvelle.etape }) {
      sortie[index] = nouvelle
    } else {
      sortie.append(nouvelle)
    }
    return sortie
  }
}

// MARK: - 2. Les sommes

enum RelaisSommes {
  /// Lit un fichier `SHA256SUMS` au format de `shasum`/`sha256sum` :
  /// `<somme>  <nom>`. Le double espace n'est pas garanti (le format « binaire »
  /// écrit `<somme> *<nom>`), donc on découpe sur l'espace et on retire une
  /// éventuelle étoile.
  static func attendue(pour fichier: String, dans texte: String) -> String? {
    for ligne in texte.split(separator: "\n", omittingEmptySubsequences: true) {
      let morceaux = ligne.split(separator: " ", omittingEmptySubsequences: true)
      guard morceaux.count >= 2 else { continue }
      var nom = String(morceaux[morceaux.count - 1])
      if nom.hasPrefix("*") { nom.removeFirst() }
      guard nom == fichier else { continue }
      let somme = String(morceaux[0]).lowercased()
      // Une somme sha256, c'est 64 caractères hexadécimaux. Le vérifier ici
      // évite de comparer une ligne de commentaire à un condensat.
      guard somme.count == 64, somme.allSatisfy(\.isHexDigit) else { continue }
      return somme
    }
    return nil
  }

  static func somme(de donnees: Data) -> String {
    SHA256.hash(data: donnees).map { String(format: "%02x", $0) }.joined()
  }

  /// Vrai si le fichier téléchargé est **exactement** celui que le
  /// `SHA256SUMS` annonce. Comparaison insensible à la casse : les deux outils
  /// n'écrivent pas la même.
  static func verifier(donnees: Data, attendue: String) -> Bool {
    somme(de: donnees).caseInsensitiveCompare(attendue) == .orderedSame
  }
}

// MARK: - 3. L'installateur

/// L'état de l'écran d'accueil pendant qu'on pose un Relais.
@MainActor
@Observable
final class RelaisInstallateur {
  static let log = Logger(subsystem: "com.correspondance.app", category: "relais-install")

  /// D'où viennent le script et ses sommes. Configurable pour l'éprouver
  /// contre un serveur local (`CORRESPONDANCE_RELEASES=http://127.0.0.1:8020`),
  /// ce qui est exactement ce que fait le rapport de la phase 6.
  nonisolated static var releases: String {
    ProcessInfo.processInfo.environment["CORRESPONDANCE_RELEASES"]
      ?? "https://github.com/menufactory43/correspondance-releases/releases/latest/download"
  }

  /// Où l'installeur pose le Relais. Même défaut que `install.sh`, même
  /// variable : l'app n'invente pas un second chemin.
  nonisolated static var prefixe: String {
    ProcessInfo.processInfo.environment["CORRESPONDANCE_RELAIS_PREFIX"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".correspondance-unclic").path()
  }

  /// Y a-t-il un Relais posé par l'installeur sur ce Mac ? On regarde la marque
  /// que `install.sh` écrit et que `uninstall.sh` exige avant d'effacer quoi que
  /// ce soit — pas un réglage, pas une croyance.
  ///
  /// Sans ça, « Tout retirer » n'existerait qu'entre la fin d'une installation
  /// et la connexion qui suit, c'est-à-dire dix secondes : l'écran d'accueil
  /// disparaît dès qu'un salon du Relais arrive, et le bouton avec lui.
  nonisolated static var poseSurCeMac: Bool {
    FileManager.default.fileExists(atPath: prefixe + "/.correspondance-relais")
  }

  enum Phase: Equatable {
    case repos
    case enCours
    case echec(String)
    case fini
  }

  private(set) var phase: Phase = .repos
  private(set) var etapes: [RelaisEtape] = []
  private(set) var mots: [String] = []
  private var processus: Process?

  var enCours: Bool { phase == .enCours }

  /// L'installation, de bout en bout. Rien n'est écrit sur le disque de
  /// l'utilisateur avant que le sha256 du script ait été confronté au
  /// `SHA256SUMS` du même endroit : télécharger un script et le lancer sans
  /// ça, c'est offrir la machine à qui contrôle le réseau.
  func installer(appairer: @escaping @MainActor (RelayPairingCode) async -> Void) async {
    await lancer(script: "relais-install.sh", arguments: ["--json"], appairer: appairer)
  }

  /// « Tout retirer » : le même chemin, le même contrôle de somme, l'autre
  /// script. Il n'y a pas de code d'appairage au bout, et c'est normal.
  func retirer() async {
    await lancer(script: "relais-uninstall.sh", arguments: [], appairer: { _ in })
  }

  private func lancer(
    script: String,
    arguments: [String],
    appairer: @escaping @MainActor (RelayPairingCode) async -> Void
  ) async {
    guard !enCours else { return }
    phase = .enCours
    etapes = []
    mots = []
    do {
      let url = try await telecharger(script: script)
      try await executer(url: url, arguments: arguments, appairer: appairer)
      if case .enCours = phase { phase = .fini }
    } catch {
      phase = .echec(error.localizedDescription)
    }
  }

  enum Erreur: LocalizedError {
    case adresse(String)
    case reseau(String)
    case sommeAbsente(String)
    case sommeFausse(String, attendue: String, vue: String)
    case scriptTombe(Int32)

    var errorDescription: String? {
      switch self {
      case .adresse(let quoi): "adresse illisible : \(quoi)"
      case .reseau(let quoi): "impossible de récupérer \(quoi) — vérifie la connexion"
      case .sommeAbsente(let nom):
        "le SHA256SUMS publié ne contient pas \(nom) : on n'exécute rien"
      case .sommeFausse(let nom, let attendue, let vue):
        "\(nom) ne correspond pas à sa somme publiée (\(vue.prefix(12))… au lieu de "
          + "\(attendue.prefix(12))…) : on n'exécute rien"
      case .scriptTombe(let code): "l'installeur s'est arrêté (code \(code))"
      }
    }
  }

  private func telecharger(script: String) async throws -> URL {
    let base = Self.releases
    let sommes = try await recuperer("\(base)/SHA256SUMS")
    guard let attendue = RelaisSommes.attendue(
      pour: script, dans: String(decoding: sommes, as: UTF8.self)
    ) else { throw Erreur.sommeAbsente(script) }
    let donnees = try await recuperer("\(base)/\(script)")
    let vue = RelaisSommes.somme(de: donnees)
    guard RelaisSommes.verifier(donnees: donnees, attendue: attendue) else {
      throw Erreur.sommeFausse(script, attendue: attendue, vue: vue)
    }
    Self.log.info("\(script, privacy: .public) : sha256 conforme")
    // Le script vit dans un dossier temporaire à nous, en 0700 : il porte des
    // droits d'exécution, il n'a rien à faire dans /tmp partagé.
    let dossier = FileManager.default.temporaryDirectory
      .appending(path: "correspondance-relais", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: dossier, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = dossier.appending(path: script)
    try donnees.write(to: url, options: [.atomic])
    return url
  }

  private func recuperer(_ adresse: String) async throws -> Data {
    guard let url = URL(string: adresse) else { throw Erreur.adresse(adresse) }
    do {
      let (donnees, reponse) = try await URLSession.shared.data(from: url)
      if let http = reponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw Erreur.reseau("\(adresse) (HTTP \(http.statusCode))")
      }
      return donnees
    } catch let erreur as Erreur {
      throw erreur
    } catch {
      throw Erreur.reseau(adresse)
    }
  }

  /// Le processus enfant, et son flux lu ligne par ligne. `bash` explicitement :
  /// le script n'a pas le bit d'exécution après un `write(to:)`, et lui donner
  /// ce bit pour ensuite le lancer serait un pas de plus pour rien.
  private func executer(
    url: URL,
    arguments: [String],
    appairer: @escaping @MainActor (RelayPairingCode) async -> Void
  ) async throws {
    let tube = Pipe()
    let processus = Process()
    processus.executableURL = URL(fileURLWithPath: "/bin/bash")
    processus.arguments = [url.path()] + arguments
    processus.standardOutput = tube
    processus.standardError = tube
    // L'environnement passe tel quel : c'est lui qui porte
    // `CORRESPONDANCE_RELEASES` et `CORRESPONDANCE_RELAIS_PREFIX` quand on
    // éprouve la carte contre un serveur local.
    processus.environment = ProcessInfo.processInfo.environment
    self.processus = processus
    defer { self.processus = nil }
    try processus.run()

    var reste = ""
    for try await morceau in tube.fileHandleForReading.bytes.lines {
      reste = morceau
      guard let evenement = RelaisFlux.analyser(ligne: morceau) else { continue }
      switch evenement {
      case .etape(let etape):
        etapes = RelaisFlux.fusionner(etapes, avec: etape)
        if etape.etat == .erreur { phase = .echec(etape.detail) }
      case .appairage(let code, let mots):
        self.mots = mots
        if let lu = RelayPairingCode(encoded: code) {
          await appairer(lu)
          phase = .fini
        } else {
          phase = .echec("l'installeur a rendu un code illisible")
        }
      }
    }
    processus.waitUntilExit()
    _ = reste
    if processus.terminationStatus != 0, case .enCours = phase {
      throw Erreur.scriptTombe(processus.terminationStatus)
    }
  }
}
