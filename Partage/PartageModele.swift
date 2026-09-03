import CorrespondanceCore
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Ce que la feuille de partage fait, sur iPhone comme sur Mac : lire ce
/// qu'on lui tend, montrer les fils, et faire partir vers celui qu'on choisit.
///
/// Compilé dans les **deux** extensions, jamais dans l'app. La différence
/// entre les deux plateformes tient en une valeur, `Partage.voie` : sur iPhone
/// on envoie soi-même, sur Mac on dépose et on réveille l'app.
@MainActor
@Observable
final class PartageModele {
  enum Etat: Equatable {
    /// On lit encore ce que l'autre app nous a donné.
    case lecture
    case pret
    case envoi
    /// Parti, ou posé pour l'app : `message` dit lequel.
    case fini(String)
    case echec(String)
  }

  let boite: PartageBoite?
  private(set) var destinataires: [Partage.Destinataire] = []
  var requete = ""
  var choisi: Partage.Destinataire?
  var mot = ""
  private(set) var contenu = Partage.Contenu()
  private(set) var etat: Etat = .lecture
  /// Une session dans le Trousseau partagé : sans elle, tout passe par l'app.
  private(set) var sessionDisponible = false
  /// La dernière voie prise, pour que la vue dise la bonne chose.
  private(set) var voiePrise: Partage.Voie?

  private let journal = Logger(subsystem: "app.correspondance", category: "partage")
  /// Les copies de travail : effacées quand la feuille se ferme.
  private let dossierDeTravail: URL

  init(boite: PartageBoite? = .partagee()) {
    self.boite = boite
    dossierDeTravail = FileManager.default.temporaryDirectory
      .appendingPathComponent("partage-\(UUID().uuidString)", isDirectory: true)
    destinataires = boite?.lireIndex()?.destinataires ?? []
    #if os(iOS)
      MatrixCredentialStore.accessGroup = SharedRelayState.keychainAccessGroup
      sessionDisponible = MatrixCredentialStore.load() != nil
    #endif
  }

  var visibles: [Partage.Destinataire] { Partage.classer(destinataires, requete: requete) }

  var peutEnvoyer: Bool {
    guard case .pret = etat, choisi != nil else { return false }
    return !contenu.estVide || !mot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Ce qu'on a en main, en une ligne : « 3 photos », « un lien », « une vidéo ».
  var resume: String {
    let fichiers = contenu.fichiers
    let images = fichiers.filter { Self.type(de: $0)?.conforms(to: .image) ?? false }.count
    let videos = fichiers.filter { Self.type(de: $0)?.conforms(to: .movie) ?? false }.count
    let autres = fichiers.count - images - videos
    var parts: [String] = []
    if images > 0 { parts.append(images == 1 ? "une photo" : "\(images) photos") }
    if videos > 0 { parts.append(videos == 1 ? "une vidéo" : "\(videos) vidéos") }
    if autres > 0 { parts.append(autres == 1 ? "un fichier" : "\(autres) fichiers") }
    let texte = contenu.texte.trimmingCharacters(in: .whitespacesAndNewlines)
    if !texte.isEmpty {
      parts.append(URL(string: texte)?.scheme?.hasPrefix("http") == true ? "un lien" : "un texte")
    }
    return parts.joined(separator: ", ")
  }

  func avatar(_ destinataire: Partage.Destinataire) -> Data? {
    boite?.avatar(destinataire.avatarFile)
  }

  // MARK: - Lire ce qu'on nous tend

  /// Les attachements des `NSExtensionItem`, dans l'ordre. Un fichier devient
  /// une copie chez nous (le système reprend le sien à la sortie du bloc) ; une
  /// adresse ou une phrase s'ajoute au texte.
  func charger(_ items: [NSExtensionItem], preselection: String?) async {
    var fichiers: [URL] = []
    var textes: [String] = []
    try? FileManager.default.createDirectory(at: dossierDeTravail, withIntermediateDirectories: true)
    for item in items {
      for fournisseur in item.attachments ?? [] {
        if let url = await Self.fichier(de: fournisseur, dans: dossierDeTravail) {
          fichiers.append(url)
        } else if let texte = await Self.texte(de: fournisseur) {
          textes.append(texte)
        }
      }
    }
    // Un partage sans pièce jointe ni adresse peut porter son texte dans
    // l'item lui-même (Safari, Notes).
    if fichiers.isEmpty, textes.isEmpty {
      for item in items {
        if let s = item.attributedContentText?.string, !s.trimmingCharacters(in: .whitespaces).isEmpty {
          textes.append(s)
        }
      }
    }
    contenu = Partage.Contenu(fichiers: fichiers, texte: textes.joined(separator: "\n"))
    if let preselection, let trouve = destinataires.first(where: { $0.id == preselection }) {
      choisi = trouve
    }
    etat = destinataires.isEmpty
      ? .echec("Ouvre Correspondance une fois pour que tes conversations apparaissent ici.")
      : .pret
  }

  private static func fichier(de fournisseur: NSItemProvider, dans dossier: URL) async -> URL? {
    // L'ordre compte : Photos annonce `public.image` ET `public.jpeg` ; Safari
    // annonce `public.url` pour une page, mais `public.file-url` pour un
    // téléchargement. On prend le type le plus précis que le fournisseur
    // sait donner en fichier.
    // Le fichier lui-même d'abord, quand l'autre app le tend (Finder, Fichiers) :
    // il garde son nom et son format. Une représentation `public.image` d'un
    // PNG arrive sinon sous le nom « PNG image.png » — vu au premier essai.
    let candidats: [UTType] = [.fileURL, .movie, .image, .pdf, .audio, .data]
    for type in candidats where fournisseur.hasItemConformingToTypeIdentifier(type.identifier) {
      if type == .fileURL {
        guard case .url(let url) = await charger(fournisseur, type), url.isFileURL else { continue }
        return copier(url, dans: dossier)
      }
      if type == .data, fournisseur.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        // Une adresse web se présente aussi en `public.data` : ce n'est pas un fichier.
        continue
      }
      if let url = await representationFichier(fournisseur, type, dans: dossier) { return url }
    }
    return nil
  }

  private static func texte(de fournisseur: NSItemProvider) async -> String? {
    if fournisseur.hasItemConformingToTypeIdentifier(UTType.url.identifier),
       case .url(let url) = await charger(fournisseur, .url), !url.isFileURL {
      return url.absoluteString
    }
    if fournisseur.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
       case .texte(let s) = await charger(fournisseur, .plainText) {
      return s
    }
    return nil
  }

  /// Ce qu'un `loadItem` rend, réduit à une valeur qui traverse les acteurs :
  /// le système livre des `NSSecureCoding` qui ne sont pas `Sendable`.
  private enum Valeur: Sendable {
    case url(URL)
    case texte(String)
    case rien
  }

  private static func charger(_ fournisseur: NSItemProvider, _ type: UTType) async -> Valeur {
    await withCheckedContinuation { suite in
      fournisseur.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        switch item {
        case let url as URL: suite.resume(returning: .url(url))
        case let s as String: suite.resume(returning: .texte(s))
        case let a as NSAttributedString: suite.resume(returning: .texte(a.string))
        case let d as Data:
          if let url = URL(dataRepresentation: d, relativeTo: nil), url.scheme != nil {
            suite.resume(returning: .url(url))
          } else if let s = String(data: d, encoding: .utf8) {
            suite.resume(returning: .texte(s))
          } else {
            suite.resume(returning: .rien)
          }
        default: suite.resume(returning: .rien)
        }
      }
    }
  }

  /// `loadFileRepresentation` prête un fichier le temps du bloc : on le copie
  /// dedans, sinon il n'existe plus à la sortie.
  private static func representationFichier(
    _ fournisseur: NSItemProvider, _ type: UTType, dans dossier: URL
  ) async -> URL? {
    await withCheckedContinuation { suite in
      fournisseur.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return suite.resume(returning: nil) }
        suite.resume(returning: copier(url, dans: dossier))
      }
    }
  }

  private static func copier(_ source: URL, dans dossier: URL) -> URL? {
    let acces = source.startAccessingSecurityScopedResource()
    defer { if acces { source.stopAccessingSecurityScopedResource() } }
    var nom = source.lastPathComponent
    if nom.isEmpty || nom == "/" { nom = "partage" }
    var cible = dossier.appendingPathComponent(nom)
    var n = 2
    while FileManager.default.fileExists(atPath: cible.path) {
      let ext = source.pathExtension
      let racine = ext.isEmpty ? nom : String(nom.dropLast(ext.count + 1))
      cible = dossier.appendingPathComponent(ext.isEmpty ? "\(racine)-\(n)" : "\(racine)-\(n).\(ext)")
      n += 1
    }
    do {
      try FileManager.default.copyItem(at: source, to: cible)
    } catch {
      return nil
    }
    return ImageConversion.jpegSiHEIC(cible)
  }

  private static func type(de url: URL) -> UTType? {
    UTType(filenameExtension: url.pathExtension)
  }

  // MARK: - Faire partir

  /// Rend vrai quand la feuille peut se fermer sur un succès.
  @discardableResult
  func envoyer() async -> Bool {
    guard let choisi, peutEnvoyer else { return false }
    etat = .envoi
    let message = contenu.message(avecMot: mot)
    let voie = Partage.voie(pour: choisi, sessionDisponible: sessionDisponible)
    voiePrise = voie
    switch voie {
    case .directe(let roomID):
      do {
        try await envoyerDirectement(roomID: roomID, message: message)
        etat = .fini("Envoyé à \(choisi.title)")
        return true
      } catch {
        journal.error("envoi direct impossible : \(error.localizedDescription, privacy: .public)")
        // Le Relais n'a pas répondu : on pose pour l'app, qui réessaiera
        // par son chemin ordinaire dès qu'on l'ouvre.
        return deposer(pour: choisi, message: message, apres: error)
      }
    case .parApp:
      return deposer(pour: choisi, message: message, apres: nil)
    }
  }

  private func envoyerDirectement(roomID: String, message: String) async throws {
    guard let credentials = MatrixCredentialStore.load() else {
      throw MatrixError.notConfigured
    }
    let client = MatrixClient(credentials: credentials)
    for fichier in contenu.fichiers {
      try await client.sendAttachment(roomID: roomID, fileURL: fichier)
    }
    if !message.isEmpty {
      try await client.sendText(roomID: roomID, body: message)
    }
  }

  private func deposer(pour choisi: Partage.Destinataire, message: String, apres erreur: Error?) -> Bool {
    guard let boite else {
      etat = .echec("Le dossier partagé avec Correspondance n'est pas accessible.")
      return false
    }
    do {
      try boite.deposer(
        conversationID: choisi.id, network: choisi.network, text: message, fichiers: contenu.fichiers)
    } catch {
      etat = .echec("Impossible de poser le partage : \(error.localizedDescription)")
      return false
    }
    let reveille = reveillerLApp()
    switch (reveille, erreur) {
    case (true, _):
      etat = .fini("Correspondance l'envoie à \(choisi.title)")
    case (false, nil):
      etat = .fini("Partira à l'ouverture de Correspondance")
    case (false, .some):
      etat = .fini("Le Relais n'a pas répondu : partira à l'ouverture de Correspondance")
    }
    return true
  }

  /// Sur Mac, `correspondance://partage` lance l'app, ou la prévient si elle
  /// tourne. Sur iPhone, une extension de partage n'a pas le droit d'ouvrir
  /// une app : c'est l'app qui vide la boîte à son prochain réveil.
  private func reveillerLApp() -> Bool {
    #if os(macOS)
      return NSWorkspace.shared.open(Partage.urlDeReveil)
    #else
      return false
    #endif
  }

  func nettoyer() {
    try? FileManager.default.removeItem(at: dossierDeTravail)
  }
}

/// Une photo iPhone arrive en HEIC, que WhatsApp et Signal montrent comme un
/// fichier à télécharger. En JPEG, c'est une photo partout.
enum ImageConversion {
  static func jpegSiHEIC(_ url: URL) -> URL {
    guard ["heic", "heif"].contains(url.pathExtension.lowercased()),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return url }
    let cible = url.deletingPathExtension().appendingPathExtension("jpg")
    guard let destination = CGImageDestinationCreateWithURL(cible as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return url }
    // L'orientation vit dans les métadonnées : on la recopie, sinon la photo
    // arrive couchée.
    var proprietes: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let orientation = meta[kCGImagePropertyOrientation] {
      proprietes[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(destination, image, proprietes as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return url }
    try? FileManager.default.removeItem(at: url)
    return cible
  }
}
