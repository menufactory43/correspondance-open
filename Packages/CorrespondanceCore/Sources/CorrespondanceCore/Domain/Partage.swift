import Foundation

/// LE PARTAGE DEPUIS LES AUTRES APPS : Photos, Safari, Fichiers, le Finder.
///
/// On tape Partager, on choisit une personne, et la photo ou le lien part sur
/// son réseau sans ouvrir Correspondance. C'est ce que font Messages, WhatsApp,
/// Signal et Beeper sur iPhone ; sur Mac, Beeper ne le peut pas (Electron).
///
/// L'extension de partage est un **autre processus**, dans son propre bac à
/// sable, qui vit quelques secondes. Elle ne tient ni `/sync`, ni modèle, ni
/// base. Ce fichier est tout ce qu'elle partage avec l'app, et il est pur :
/// des valeurs, des fichiers dans le conteneur du groupe d'app, aucun réseau.
///
/// Deux choses transitent par le conteneur, dans les deux sens :
///
/// - **L'index des destinataires**, écrit par l'app après chaque
///   rafraîchissement : les fils, leur titre, leur réseau, leur photo. C'est ce
///   que l'extension montre dans sa liste, sans rien demander à personne.
/// - **La boîte de dépôt**, écrite par l'extension quand elle ne peut pas
///   envoyer elle-même : les fichiers et le mot qui les accompagne, posés
///   pour que l'app les envoie par son chemin ordinaire au prochain réveil.
///
/// Sur iPhone, l'extension envoie **elle-même** dès qu'elle le peut — tous les
/// fils y vivent sur le Relais, et la session est dans le Trousseau partagé —
/// et ne dépose que si le Relais ne répond pas. Sur Mac, elle dépose
/// **toujours** : iMessage passe par l'automatisation de Messages, qu'une
/// extension ne sait pas piloter, et l'app y est de toute façon presque
/// toujours ouverte. Cf. `Partage.Voie`.
public enum Partage {
  /// Le dossier des dépôts et de l'index, sous le conteneur partagé.
  public static let dossier = "Partage"
  /// L'adresse qui réveille l'app pour vider la boîte : `correspondance://partage`.
  public static let schemaURL = "correspondance"
  public static let urlDeReveil = URL(string: "correspondance://partage")!

  // MARK: - Ce que l'extension montre

  /// Un fil, tel que la liste de l'extension le présente.
  public struct Destinataire: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var network: MessageNetwork
    public var isGroup: Bool
    public var lastMessageAt: Date
    /// Le nom du fichier de la photo dans `avatars/`, quand l'app en avait une.
    public var avatarFile: String?
    /// Un salon chiffré : écrire une clé de session dans le magasin partagé
    /// depuis un second processus n'est pas quelque chose qu'on fait — c'est
    /// l'app qui enverra.
    public var isEncrypted: Bool

    public init(
      id: String, title: String, network: MessageNetwork, isGroup: Bool = false,
      lastMessageAt: Date, avatarFile: String? = nil, isEncrypted: Bool = false
    ) {
      self.id = id
      self.title = title
      self.network = network
      self.isGroup = isGroup
      self.lastMessageAt = lastMessageAt
      self.avatarFile = avatarFile
      self.isEncrypted = isEncrypted
    }

    /// Le salon Matrix du fil, pour l'envoi direct. `nil` pour iMessage.
    public var roomID: String? { MatrixSyncParser.roomID(inConversationID: id) }
  }

  public struct Index: Codable, Sendable, Equatable {
    public var destinataires: [Destinataire]
    public var updatedAt: Date

    public init(destinataires: [Destinataire], updatedAt: Date = .now) {
      self.destinataires = destinataires
      self.updatedAt = updatedAt
    }
  }

  /// L'index tel que l'app le construit : les fils actifs, les plus récents
  /// d'abord. Les archivés n'y sont pas — on n'envoie pas une photo dans une
  /// conversation qu'on a rangée, et s'il le faut on l'ouvre dans l'app.
  public static func index(
    conversations: [Conversation],
    avatarFile: (Conversation) -> String? = { _ in nil },
    now: Date = .now
  ) -> Index {
    let rows = conversations
      .filter { !$0.isArchived && !$0.hasPlaceholderTitle }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
      .map {
        Destinataire(
          id: $0.id, title: $0.title, network: $0.network, isGroup: $0.isGroup,
          lastMessageAt: $0.lastMessageAt, avatarFile: avatarFile($0),
          isEncrypted: $0.encryptionAlgorithm != nil
        )
      }
    return Index(destinataires: rows, updatedAt: now)
  }

  /// Ce que la recherche de l'extension rend : sans requête, l'ordre de l'index ;
  /// avec, les titres qui contiennent chaque mot, sans accents ni casse.
  public static func classer(_ destinataires: [Destinataire], requete: String) -> [Destinataire] {
    let mots = requete.split(whereSeparator: \.isWhitespace).map { plie(String($0)) }
    guard !mots.isEmpty else { return destinataires }
    return destinataires.filter { row in
      let titre = plie(row.title)
      let reseau = plie(row.network.labelFR)
      return mots.allSatisfy { titre.contains($0) || reseau.contains($0) }
    }
  }

  private static func plie(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
  }

  // MARK: - Ce que l'extension dépose

  /// Un partage posé pour l'app : les fichiers sont à côté, dans le dossier du
  /// dépôt, et `fichiers` en donne les noms dans l'ordre choisi.
  public struct Depot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var conversationID: String
    public var network: MessageNetwork
    public var text: String
    public var fichiers: [String]
    public var createdAt: Date

    public init(
      id: String = UUID().uuidString, conversationID: String, network: MessageNetwork,
      text: String, fichiers: [String],
      // À la seconde : la fiche voyage en ISO 8601, qui n'en garde pas plus,
      // et une date relue doit être égale à celle qu'on a écrite.
      createdAt: Date = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    ) {
      self.id = id
      self.conversationID = conversationID
      self.network = network
      self.text = text
      self.fichiers = fichiers
      self.createdAt = createdAt
    }
  }

  // MARK: - Par où ça part

  /// L'extension envoie-t-elle elle-même, ou laisse-t-elle l'app le faire ?
  public enum Voie: Equatable, Sendable {
    /// L'extension parle au Relais : upload, puis l'événement, avec la
    /// session du Trousseau partagé. Le partage est parti quand elle se ferme.
    case directe(roomID: String)
    /// L'extension dépose, et réveille l'app, qui envoie par son chemin
    /// ordinaire — bulle optimiste, Messages pour iMessage, tout pareil.
    case parApp
  }

  public enum Plateforme: Sendable { case iOS, macOS }

  public static var plateforme: Plateforme {
    #if os(iOS)
      .iOS
    #else
      .macOS
    #endif
  }

  /// Sur iPhone, directe dès que le fil a un salon en clair et qu'on a une
  /// session ; sur Mac, toujours par l'app. Un fil sans salon (iMessage) n'a de toute
  /// façon que l'app pour partir.
  public static func voie(
    pour destinataire: Destinataire,
    sessionDisponible: Bool,
    plateforme: Plateforme = Self.plateforme
  ) -> Voie {
    guard plateforme == .iOS, sessionDisponible,
          destinataire.network.livesOnRelay, !destinataire.isEncrypted,
          let roomID = destinataire.roomID
    else { return .parApp }
    return .directe(roomID: roomID)
  }

  // MARK: - Ce que le partage porte

  /// Ce que la feuille de partage nous tend, une fois lu : des fichiers déjà
  /// copiés chez nous, et du texte (une adresse, une phrase).
  public struct Contenu: Sendable, Equatable {
    public var fichiers: [URL] = []
    public var texte: String = ""

    public init(fichiers: [URL] = [], texte: String = "") {
      self.fichiers = fichiers
      self.texte = texte
    }

    public var estVide: Bool {
      fichiers.isEmpty && texte.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Le mot de l'utilisateur d'abord, puis ce que l'autre app nous a donné
    /// (le lien). Une phrase et un lien font un message ; un lien seul aussi.
    public func message(avecMot mot: String) -> String {
      [mot, texte]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
  }
}

// MARK: - Les fichiers

/// Le dossier partagé lui-même : l'index, les photos, les dépôts. Un `base`
/// injectable, pour que les tests vivent dans un dossier temporaire.
public struct PartageBoite: Sendable {
  public let base: URL

  public init(base: URL) {
    self.base = base
  }

  /// La boîte dans le conteneur du groupe d'app, ou `nil` si le groupe n'est
  /// pas accessible à ce processus.
  ///
  /// Sur Mac, le conteneur existe pour n'importe quel identifiant quand on est
  /// hors bac à sable ; c'est justement ce qu'on veut ici, l'app y écrit et
  /// l'extension, elle, n'y accède que par son entitlement.
  public static func partagee(
    appGroup: String = SharedRelayState.appGroupDuPartage,
    fileManager: FileManager = .default
  ) -> PartageBoite? {
    guard let conteneur = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    return PartageBoite(base: conteneur.appendingPathComponent(Partage.dossier, isDirectory: true))
  }

  public var avatars: URL { base.appendingPathComponent("avatars", isDirectory: true) }
  public var depots: URL { base.appendingPathComponent("depots", isDirectory: true) }
  private var indexURL: URL { base.appendingPathComponent("index.json") }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  // MARK: L'index

  public func ecrire(_ index: Partage.Index) throws {
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Self.encoder.encode(index).write(to: indexURL, options: [.atomic])
  }

  public func lireIndex() -> Partage.Index? {
    guard let data = try? Data(contentsOf: indexURL) else { return nil }
    return try? Self.decoder.decode(Partage.Index.self, from: data)
  }

  /// Pose une photo, nommée d'après ce qui l'identifie (un `mxc`, un chemin) :
  /// la même photo n'est écrite qu'une fois. Rend le nom du fichier.
  @discardableResult
  public func poserAvatar(_ data: Data, cle: String) -> String? {
    let nom = Self.nomSur(cle) + ".img"
    let url = avatars.appendingPathComponent(nom)
    if FileManager.default.fileExists(atPath: url.path) { return nom }
    do {
      try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
      return nom
    } catch {
      return nil
    }
  }

  public func avatar(_ nom: String?) -> Data? {
    guard let nom else { return nil }
    return try? Data(contentsOf: avatars.appendingPathComponent(nom))
  }

  /// Les photos dont l'index ne parle plus n'ont rien à faire là.
  public func balayerAvatars(gardant index: Partage.Index) {
    let gardes = Set(index.destinataires.compactMap(\.avatarFile))
    let fm = FileManager.default
    for nom in (try? fm.contentsOfDirectory(atPath: avatars.path)) ?? [] where !gardes.contains(nom) {
      try? fm.removeItem(at: avatars.appendingPathComponent(nom))
    }
  }

  private static func nomSur(_ cle: String) -> String {
    // Un hachage stable et court : le nom du fichier n'a pas à raconter la clé.
    var h: UInt64 = 1469598103934665603
    for b in cle.utf8 {
      h ^= UInt64(b)
      h = h &* 1099511628211
    }
    return String(h, radix: 36)
  }

  // MARK: Les dépôts

  /// Copie les fichiers dans un dossier à part et écrit la fiche. Le dossier
  /// porte l'identifiant du dépôt ; la fiche s'écrit en dernier, pour qu'un
  /// dépôt à moitié copié n'existe pas aux yeux de l'app.
  @discardableResult
  public func deposer(
    conversationID: String, network: MessageNetwork, text: String, fichiers: [URL]
  ) throws -> Partage.Depot {
    let depot = Partage.Depot(
      conversationID: conversationID, network: network, text: text,
      fichiers: fichiers.map(\.lastPathComponent)
    )
    let dossier = depots.appendingPathComponent(depot.id, isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
    var noms: [String] = []
    for source in fichiers {
      var nom = source.lastPathComponent
      // Deux fichiers du même nom dans un partage (deux « IMG_0001.jpg » de
      // deux albums) : le second prend un suffixe, sans perdre son extension.
      if noms.contains(nom) {
        let ext = source.pathExtension
        let racine = ext.isEmpty ? nom : String(nom.dropLast(ext.count + 1))
        nom = ext.isEmpty ? "\(racine)-\(noms.count + 1)" : "\(racine)-\(noms.count + 1).\(ext)"
      }
      try fm.copyItem(at: source, to: dossier.appendingPathComponent(nom))
      noms.append(nom)
    }
    var fiche = depot
    fiche.fichiers = noms
    try Self.encoder.encode(fiche).write(to: dossier.appendingPathComponent("depot.json"), options: [.atomic])
    return fiche
  }

  /// Les dépôts en attente, du plus ancien au plus récent.
  public func enAttente() -> [Partage.Depot] {
    let fm = FileManager.default
    guard let noms = try? fm.contentsOfDirectory(atPath: depots.path) else { return [] }
    return noms
      .compactMap { nom -> Partage.Depot? in
        let fiche = depots.appendingPathComponent(nom).appendingPathComponent("depot.json")
        guard let data = try? Data(contentsOf: fiche) else { return nil }
        return try? Self.decoder.decode(Partage.Depot.self, from: data)
      }
      .sorted { $0.createdAt < $1.createdAt }
  }

  /// Les fichiers d'un dépôt, dans l'ordre de la fiche.
  public func fichiers(de depot: Partage.Depot) -> [URL] {
    let dossier = depots.appendingPathComponent(depot.id, isDirectory: true)
    return depot.fichiers.map { dossier.appendingPathComponent($0) }
  }

  /// Sort les fichiers d'un dépôt vers `destination` et efface le dépôt : ce
  /// que l'app garde en vol (la bulle et sa vignette) ne doit pas dépendre
  /// d'un dossier que l'extension pourrait recréer.
  public func retirer(_ depot: Partage.Depot, vers destination: URL) throws -> [URL] {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    var sortis: [URL] = []
    for source in fichiers(de: depot) {
      let cible = destination.appendingPathComponent(source.lastPathComponent)
      try? fm.removeItem(at: cible)
      try fm.moveItem(at: source, to: cible)
      sortis.append(cible)
    }
    try? fm.removeItem(at: depots.appendingPathComponent(depot.id, isDirectory: true))
    return sortis
  }

  public func retirer(_ depot: Partage.Depot) {
    try? FileManager.default.removeItem(at: depots.appendingPathComponent(depot.id, isDirectory: true))
  }
}

extension SharedRelayState {
  /// Le groupe d'app du partage, par plateforme.
  ///
  /// Sur iPhone, celui de l'extension de notification. Sur Mac, la forme
  /// préfixée par l'équipe : c'est celle qu'un binaire Developer ID porte
  /// sans profil d'approvisionnement, et sans la boîte de consentement que
  /// macOS 15 pose devant un groupe `group.` qu'aucun profil ne nomme.
  public static var appGroupDuPartage: String {
    #if os(iOS)
      appGroup
    #else
      "AKMNXGVVGX.app.correspondance"
    #endif
  }
}
