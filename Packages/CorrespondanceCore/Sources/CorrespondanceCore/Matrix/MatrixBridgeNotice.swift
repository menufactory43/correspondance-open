import Foundation

/// Ce qu'un bot de pont dit dans un portail, rendu en français quand on le
/// reconnaît. Le texte d'origine reste la source : un avis inconnu s'affiche
/// tel quel, jamais inventé.
public enum MatrixBridgeNotice {
  public static func systemText(for body: String) -> String {
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    if lower.contains("will now be relayed through") {
      return "Relais du pont allumé : cc parle ici à voix haute, depuis ton compte."
    }
    if lower.contains("stopped relaying")
      || (lower.contains("relay") && (lower.contains("unset") || lower.contains("disabled") || lower.contains("no longer"))) {
      return "Relais du pont éteint : cc propose des brouillons, visibles de toi seul."
    }
    if lower.contains("not bridged") {
      return "Message non relayé par le pont : " + text
    }
    return "Pont : " + text
  }

  /// « !wa set-relay », « !fb unset-relay » : une commande au pont de ce
  /// réseau, pas un message.
  public static func isBridgeCommand(_ body: String, network: MessageNetwork) -> Bool {
    guard let bridge = network.bridge else { return false }
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.hasPrefix(bridge.commandPrefix + " ") || text == bridge.commandPrefix
  }
}
