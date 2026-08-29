import Foundation

/// Les effets d'envoi iMessage (`message.expressive_send_style_id`).
///
/// On ne rejoue pas l'effet — on l'annonce, comme le fait Messages quand on
/// désactive les animations : « envoyé avec Confettis ». Un identifiant inconnu
/// n'est pas perdu pour autant : on montre son dernier segment brut.
enum IMessageExpressiveEffect {
  /// Effets de bulle (le texte lui-même est rendu autrement) et effets d'écran.
  private static let names: [String: String] = [
    // Bulles
    "com.apple.MobileSMS.expressivesend.gentle": "Léger",
    "com.apple.MobileSMS.expressivesend.loud": "Fort",
    "com.apple.MobileSMS.expressivesend.impact": "Choc",
    "com.apple.MobileSMS.expressivesend.invisibleink": "Encre invisible",
    // Écran
    "com.apple.messages.effect.CKConfettiEffect": "Confettis",
    "com.apple.messages.effect.CKHappyBirthdayEffect": "Ballons",
    "com.apple.messages.effect.CKFireworksEffect": "Feux d’artifice",
    "com.apple.messages.effect.CKSparklesEffect": "Étincelles",
    "com.apple.messages.effect.CKLasersEffect": "Lasers",
    "com.apple.messages.effect.CKShootingStarEffect": "Étoile filante",
    "com.apple.messages.effect.CKHeartEffect": "Cœur",
    "com.apple.messages.effect.CKSpotlightEffect": "Projecteur",
    "com.apple.messages.effect.CKEchoEffect": "Écho",
    "com.apple.messages.effect.CKCelebrationEffect": "Célébration",
  ]

  /// Nom lisible de l'effet, ou `nil` s'il n'y a pas d'effet.
  static func name(for rawID: String?) -> String? {
    guard let rawID else { return nil }
    let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let known = names[trimmed] { return known }
    // Identifiant inconnu (nouvel effet système) : mieux vaut le nom brut que rien.
    let tail = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
    return tail.isEmpty ? trimmed : tail
  }

  /// Étiquette affichée sous la bulle.
  static func label(for rawID: String?) -> String? {
    name(for: rawID).map { "envoyé avec \($0)" }
  }
}

/// Les lignes de `message` qui ne sont pas des messages mais des événements de
/// groupe (`item_type` ≠ 0). Le fil les montre en séparateurs discrets.
enum IMessageGroupEvent {
  /// - Parameters:
  ///   - itemType: `message.item_type` (1 = arrivée/départ imposé, 2 = renommage, 3 = départ ou photo).
  ///   - actionType: `message.group_action_type` (0 = ajout / changement, 1 = retrait / photo).
  ///   - groupTitle: `message.group_title`, renseigné au renommage.
  ///   - actor: qui a agi — nom lisible déjà résolu ; ignoré si l'action est mienne.
  ///   - target: la personne concernée (`other_handle`), quand il y en a une.
  ///   - isFromMe: l'action est la mienne — la phrase passe à « Vous avez… ».
  /// - Returns: la phrase à afficher, ou `nil` si la ligne n'est pas un événement connu.
  static func label(
    itemType: Int,
    actionType: Int,
    groupTitle: String?,
    actor: String?,
    target: String?,
    isFromMe: Bool = false
  ) -> String? {
    let who = isFromMe ? "Vous" : (cleaned(actor) ?? "Quelqu’un")
    let whom = cleaned(target)

    switch itemType {
    case 1:
      let verb = conjugated(actionType == 1 ? "retiré" : "ajouté", isFromMe: isFromMe)
      return "\(who) \(verb) \(whom ?? "une personne")"
    case 2:
      guard let title = cleaned(groupTitle) else {
        return "\(who) \(conjugated("renommé", isFromMe: isFromMe)) la conversation"
      }
      return "\(who) \(conjugated("nommé", isFromMe: isFromMe)) la conversation « \(title) »"
    case 3:
      // `group_action_type` 1 sur un `item_type` 3 = la photo du groupe a changé,
      // pas un départ : Messages range les deux sous le même type d'élément.
      return actionType == 1
        ? "\(who) \(conjugated("changé", isFromMe: isFromMe)) la photo de la conversation"
        : "\(who) \(conjugated("quitté", isFromMe: isFromMe)) la conversation"
    default:
      return nil
    }
  }

  /// « a ajouté » pour les autres, « avez ajouté » pour moi — les quatre verbes
  /// employés ici se conjuguent tous avec l'auxiliaire avoir.
  private static func conjugated(_ participle: String, isFromMe: Bool) -> String {
    isFromMe ? "avez \(participle)" : "a \(participle)"
  }

  private static func cleaned(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
