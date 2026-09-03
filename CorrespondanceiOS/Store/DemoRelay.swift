import CorrespondanceCore
import Foundation
import UIKit

/// Un Relais de démonstration, fait des payloads `/sync` qui servent déjà de
/// fixtures aux tests de Core.
///
/// Ce n'est pas une maquette : les conversations et les messages sortent du
/// VRAI `MatrixSyncParser`, appliqué aux VRAIS payloads mautrix (WhatsApp,
/// Signal, Instagram, Messenger). Ce qui s'affiche en démonstration est donc exactement ce
/// que le Relais afficherait — noms de portails, groupes, réactions, citations,
/// accusés de lecture compris. Sert aux captures d'écran et à travailler la
/// mise en page sans NUC sous la main.
///
/// Se déclenche par l'argument de lancement `-CorrespondanceDemo` (schéma Xcode
/// ou `simctl launch … -CorrespondanceDemo`). Jamais en production.
enum DemoRelay {
  static let launchArgument = "-CorrespondanceDemo"

  static var isRequested: Bool {
    CommandLine.arguments.contains(launchArgument)
  }

  /// L'écran à ouvrir d'emblée en démonstration (`-CorrespondanceDemoScreen fil`
  /// ou `focus`). Sert aux captures : sans ça, il faudrait un doigt.
  enum Screen: String {
    case inbox
    case fil
    case focus
    /// Tente vraiment une connexion vers une adresse morte : c'est le VRAI
    /// chemin d'erreur qu'on veut voir à l'écran, pas un message posé à la main.
    case erreur
    /// File vidée : « Vous êtes à jour ».
    case vide
    /// L'écran des notifications : demande l'autorisation, et sème dans le
    /// Trousseau partagé une session pointant vers le Relais de démonstration
    /// (`-CorrespondanceDemoHomeserver`). C'est le seul moyen d'exercer
    /// l'extension de notification sans NUC : elle ira vraiment lire son
    /// événement, sur un serveur qui répond vraiment.
    case notification
    /// Les quatre écrans de la phase C2, chacun sa feuille.
    case nouvelle
    case recherche
    case plusTard
    case reglages
    /// Le fil aux photos : une mosaïque de quatre et un partage Instagram.
    case medias
  }

  /// L'adresse du Relais de démonstration, pour l'écran `notification`.
  /// Rien en dur : elle est passée au lancement, comme la vraie.
  static var demoHomeserver: URL? {
    guard isRequested,
          let raw = UserDefaults.standard.string(forKey: "CorrespondanceDemoHomeserver")
    else { return nil }
    return URL(string: raw)
  }

  /// Le couple (salon, événement) que le push nommerait — passé au lancement,
  /// comme le ferait Sygnal. `-CorrespondanceDemoPush "!salon:serveur/$event"`.
  static var demoPushReference: PushNotification.EventReference? {
    guard isRequested,
          let raw = UserDefaults.standard.string(forKey: "CorrespondanceDemoPush"),
          let slash = raw.lastIndex(of: "/")
    else { return nil }
    return PushNotification.EventReference(
      roomID: String(raw[raw.startIndex..<slash]),
      eventID: String(raw[raw.index(after: slash)...])
    )
  }

  /// Sème la session dans le Trousseau PARTAGÉ — celui que l'extension lit.
  /// Ne fait rien hors démonstration : c'est la seule garde qui compte.
  static func seedSharedCredentials() {
    guard isRequested, let homeserver = demoHomeserver else { return }
    MatrixCredentialStore.accessGroup = SharedRelayState.keychainAccessGroup
    MatrixCredentialStore.save(
      MatrixCredentials(
        homeserver: homeserver,
        userID: selfUserID,
        accessToken: "demonstration",
        deviceID: "DEMO"
      )
    )
  }

  /// L'adresse injoignable de l'écran d'erreur. Un nom qui ne résout nulle part,
  /// jamais une IP — le Relais n'en a pas en dur, sa démonstration non plus.
  static let unreachableHomeserver = "relais.injoignable.invalid:8008"


  static var requestedScreen: Screen {
    guard isRequested,
          let raw = UserDefaults.standard.string(forKey: "CorrespondanceDemoScreen")
    else { return .inbox }
    return Screen(rawValue: raw) ?? .inbox
  }

  static let selfUserID = "@meffysto:correspondance.local"

  struct Catalogue {
    var conversations: [Conversation] = []
    var messages: [String: [ChatMessage]] = [:]
    /// Qui écrit, par fil — l'EDU `m.typing` des payloads, lue par le vrai
    /// analyseur : sans elle, la bulle à trois points n'a rien à montrer.
    var typingLabels: [String: String] = [:]
    var state = InboxState()
  }

  /// Les médias que les fixtures annoncent, déposés dans le cache des pièces
  /// jointes AVANT la lecture des payloads : sans fichier sous la main, une
  /// photo bridgée ne sait dire que « indisponible », et le fil de démonstration
  /// n'aurait ni mosaïque ni carte de partage à montrer.
  private static func seedAttachments() {
    let hues: [Double] = [0.09, 0.42, 0.55, 0.86]
    for (rank, hue) in hues.enumerated() {
      seed(
        mxc: "mxc://correspondance.local/demo-album-\(rank + 1)",
        contentType: "image/png",
        size: rank.isMultiple(of: 2) ? CGSize(width: 480, height: 640) : CGSize(width: 640, height: 480),
        hue: hue
      )
    }
    seedVoice(mxc: "mxc://correspondance.local/demo-vocal-1", seconds: 7)
    seed(
      mxc: "mxc://correspondance.local/demo-reel-1",
      contentType: "image/jpeg",
      // Un reel est debout, en 9/16 : c'est ce format-là que la carte doit
      // savoir montrer sans rogner le texte incrusté.
      size: CGSize(width: 540, height: 960),
      hue: 0.72
    )
  }

  /// Le vocal de démonstration : un WAV écrit ici même, une phrase sifflée
  /// dont l'amplitude monte et retombe. Un vrai fichier, parce que la bulle
  /// mesure sa durée avec AVFoundation et ne saurait rien faire d'un leurre.
  private static func seedVoice(mxc: String, seconds: Double) {
    guard MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: "audio/wav") == nil
    else { return }
    let rate = 16_000
    let count = Int(Double(rate) * seconds)
    var samples = Data(capacity: count * 2)
    for index in 0..<count {
      let t = Double(index) / Double(rate)
      let envelope = 0.35 * abs(sin(t * 1.7)) * (0.5 + 0.5 * sin(t * 0.6))
      let value = Int16(max(-1, min(1, sin(t * 2 * .pi * 220) * envelope)) * 32_000)
      withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
    }
    var wav = Data()
    func append(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
    append("fmt "); append32(16); append16(1); append16(1)
    append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
    append("data"); append32(UInt32(samples.count))
    wav.append(samples)
    MatrixAttachmentStore.store(data: wav, forMXC: mxc, contentType: "audio/wav")
  }

  private static func seed(mxc: String, contentType: String, size: CGSize, hue: Double) {
    guard MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: contentType) == nil
    else { return }
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor(hue: hue, saturation: 0.34, brightness: 0.82, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor(hue: hue, saturation: 0.55, brightness: 0.52, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))
    }
    guard let data = contentType == "image/jpeg"
      ? image.jpegData(compressionQuality: 0.9)
      : image.pngData()
    else { return }
    MatrixAttachmentStore.store(data: data, forMXC: mxc, contentType: contentType)
  }

  static func catalogue() -> Catalogue {
    seedAttachments()
    var rooms: [String: MatrixRoomModel] = [:]
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    for name in DemoFixtures.syncNames {
      guard let response = DemoFixtures.response(named: name) else { continue }
      parser.apply(response, to: &rooms)
    }

    var catalogue = Catalogue()
    for model in rooms.values {
      guard let conversation = model.conversation(selfUserID: selfUserID) else { continue }
      catalogue.conversations.append(conversation)
      catalogue.messages[conversation.id] = model.sortedMessages
      if let typing = model.typingLabelFR(now: Date(), selfUserID: selfUserID) {
        catalogue.typingLabels[conversation.id] = typing
      }
    }

    // Un peu d'état, pour que les sections et les filtres aient quelque chose à
    // montrer : la conversation la plus ancienne est archivée, la plus récente
    // épinglée, une troisième porte un brouillon.
    let ordered = InboxOrdering.sorted(catalogue.conversations, pinned: [])
    if let first = ordered.first { catalogue.state.pinned.insert(first.id) }
    if let last = ordered.last, ordered.count > 2 { catalogue.state.archived.insert(last.id) }
    if ordered.count > 1 {
      catalogue.state.drafts[ordered[1].id] = "Je te réponds ce soir, promis —"
    }
    if let muted = ordered.first(where: \.isGroup) { catalogue.state.muted.insert(muted.id) }
    return catalogue
  }

  static func shiftingTimestamps(in json: String, now: Date = .now) -> String {
    DemoFixtures.shiftingTimestamps(in: json, now: now)
  }
}
