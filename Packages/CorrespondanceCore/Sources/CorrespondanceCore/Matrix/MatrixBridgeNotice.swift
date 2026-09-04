import Foundation

/// Ce qu'un bot de pont dit dans un portail, rendu en français quand on le
/// reconnaît. Le texte d'origine reste la source : un avis inconnu s'affiche
/// tel quel, jamais inventé.
public enum MatrixBridgeNotice {
  public static func systemText(for body: String) -> String {
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    switch relayState(in: text) {
    case .some(true): return relayOnText
    case .some(false): return relayOffText
    case .none: break
    }
    if lower.contains("not bridged") {
      return "Message non relayé par le pont : " + text
    }
    return "Pont : " + text
  }

  public static let relayOnText = "Relais du pont allumé : cc parle ici à voix haute, depuis ton compte."
  public static let relayOffText = "Relais du pont éteint : cc propose des brouillons, visibles de toi seul."

  /// Ce qu'un avis du pont dit de l'état du relais : allumé, éteint, ou rien
  /// à ce sujet. « This portal doesn't have a relay set » (Signal, en réponse
  /// à un `unset-relay` de trop) dit « éteint » — c'était affiché brut, en
  /// anglais, sous « Pont : », pour un simple passage de « Sur demande » à
  /// « Propose ».
  public static func relayState(in body: String) -> Bool? {
    let lower = body.lowercased()
    if lower.contains("will now be relayed through") { return true }
    if lower.contains("stopped relaying")
      || lower.contains("doesn't have a relay set")
      || lower.contains("does not have a relay set")
      || (lower.contains("relay") && (lower.contains("unset") || lower.contains("disabled") || lower.contains("no longer"))) {
      return false
    }
    return nil
  }

  /// L'état du relais que porte une ligne d'événement déjà traduite — celle
  /// que le fil garde en mémoire, et que le service relit avant de parler au pont.
  public static func relayState(ofSystemText text: String) -> Bool? {
    if text == relayOnText { return true }
    if text == relayOffText { return false }
    return nil
  }

  /// « !wa set-relay », « !fb unset-relay » : une commande au pont de ce
  /// réseau, pas un message.
  public static func isBridgeCommand(_ body: String, network: MessageNetwork) -> Bool {
    guard let bridge = network.bridge else { return false }
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.hasPrefix(bridge.commandPrefix + " ") || text == bridge.commandPrefix
  }
}
