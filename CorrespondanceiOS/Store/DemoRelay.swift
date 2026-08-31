import CorrespondanceCore
import Foundation

/// Un Relais de démonstration, fait des payloads `/sync` qui servent déjà de
/// fixtures aux tests de Core.
///
/// Ce n'est pas une maquette : les conversations et les messages sortent du
/// VRAI `MatrixSyncParser`, appliqué aux VRAIS payloads mautrix (WhatsApp,
/// Signal, Instagram). Ce qui s'affiche en démonstration est donc exactement ce
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
    var state = InboxState()
  }

  static func catalogue() -> Catalogue {
    var rooms: [String: MatrixRoomModel] = [:]
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    for name in ["matrix-sync-whatsapp", "matrix-sync-signal", "matrix-sync-instagram"] {
      guard let response = response(named: name) else { continue }
      parser.apply(response, to: &rooms)
    }

    var catalogue = Catalogue()
    for model in rooms.values {
      guard let conversation = model.conversation(selfUserID: selfUserID) else { continue }
      catalogue.conversations.append(conversation)
      catalogue.messages[conversation.id] = model.sortedMessages
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

  /// Décode un payload, en ramenant ses horodatages à aujourd'hui : une inbox
  /// de démonstration datée de l'an dernier ne dit rien de la mise en page des
  /// heures et des jours, qui est justement ce qu'on veut regarder.
  private static func response(named name: String) -> MatrixSyncResponse? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
          let raw = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    let shifted = shiftingTimestamps(in: raw)
    guard let data = shifted.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(MatrixSyncResponse.self, from: data)
  }

  /// Décale tous les `origin_server_ts` pour que le plus récent tombe il y a
  /// quelques minutes. Purement textuel : le payload reste un payload Matrix.
  static func shiftingTimestamps(in json: String, now: Date = .now) -> String {
    let pattern = #""origin_server_ts"\s*:\s*(\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
    let full = NSRange(json.startIndex..., in: json)
    let matches = regex.matches(in: json, range: full)
    let values: [Int] = matches.compactMap {
      guard let range = Range($0.range(at: 1), in: json) else { return nil }
      return Int(json[range])
    }
    guard let newest = values.max() else { return json }
    let target = Int(now.addingTimeInterval(-8 * 60).timeIntervalSince1970 * 1000)
    let delta = target - newest

    var result = json
    for match in matches.reversed() {
      guard let whole = Range(match.range, in: result),
            let digits = Range(match.range(at: 1), in: result),
            let value = Int(result[digits])
      else { continue }
      result.replaceSubrange(whole, with: "\"origin_server_ts\": \(value + delta)")
    }
    return result
  }
}
