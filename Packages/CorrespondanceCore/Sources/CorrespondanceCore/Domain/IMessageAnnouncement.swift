import Foundation

/// Les effets d'envoi iMessage (`message.expressive_send_style_id`).
///
/// On ne rejoue pas l'effet — on l'annonce, comme le fait Messages quand on
/// désactive les animations : « envoyé avec Confettis ». Un identifiant inconnu
/// n'est pas perdu pour autant : on montre son dernier segment brut.
public enum IMessageExpressiveEffect {
  /// Effets de bulle (le texte lui-même est rendu autrement) et effets d'écran.
  private static let names: [String: String] = [
    // Bulles
    "com.apple.MobileSMS.expressivesend.gentle": String(localized: "Léger"),
    "com.apple.MobileSMS.expressivesend.loud": String(localized: "Fort"),
    "com.apple.MobileSMS.expressivesend.impact": String(localized: "Choc"),
    "com.apple.MobileSMS.expressivesend.invisibleink": String(localized: "Encre invisible"),
    // Écran
    "com.apple.messages.effect.CKConfettiEffect": String(localized: "Confettis"),
    "com.apple.messages.effect.CKHappyBirthdayEffect": String(localized: "Ballons"),
    "com.apple.messages.effect.CKFireworksEffect": String(localized: "Feux d’artifice"),
    "com.apple.messages.effect.CKSparklesEffect": String(localized: "Étincelles"),
    "com.apple.messages.effect.CKLasersEffect": String(localized: "Lasers"),
    "com.apple.messages.effect.CKShootingStarEffect": String(localized: "Étoile filante"),
    "com.apple.messages.effect.CKHeartEffect": String(localized: "Cœur"),
    "com.apple.messages.effect.CKSpotlightEffect": String(localized: "Projecteur"),
    "com.apple.messages.effect.CKEchoEffect": String(localized: "Écho"),
    "com.apple.messages.effect.CKCelebrationEffect": String(localized: "Célébration"),
  ]

  /// Nom lisible de l'effet, ou `nil` s'il n'y a pas d'effet.
  public static func name(for rawID: String?) -> String? {
    guard let rawID else { return nil }
    let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let known = names[trimmed] { return known }
    // Identifiant inconnu (nouvel effet système) : mieux vaut le nom brut que rien.
    let tail = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
    return tail.isEmpty ? trimmed : tail
  }

  /// Étiquette affichée sous la bulle.
  public static func label(for rawID: String?) -> String? {
    name(for: rawID).map { String(localized: "envoyé avec \($0)") }
  }
}

/// Les lignes de `message` qui ne sont pas des messages mais des événements de
/// groupe (`item_type` ≠ 0). Le fil les montre en séparateurs discrets.
public enum IMessageGroupEvent {
  /// - Parameters:
  ///   - itemType: `message.item_type` (1 = arrivée/départ imposé, 2 = renommage, 3 = départ ou photo).
  ///   - actionType: `message.group_action_type` (0 = ajout / changement, 1 = retrait / photo).
  ///   - groupTitle: `message.group_title`, renseigné au renommage.
  ///   - actor: qui a agi — nom lisible déjà résolu ; ignoré si l'action est mienne.
  ///   - target: la personne concernée (`other_handle`), quand il y en a une.
  ///   - isFromMe: l'action est la mienne — la phrase passe à « Vous avez… ».
  /// - Returns: la phrase à afficher, ou `nil` si la ligne n'est pas un événement connu.
  public static func label(
    itemType: Int,
    actionType: Int,
    groupTitle: String?,
    actor: String?,
    target: String?,
    isFromMe: Bool = false
  ) -> String? {
    let who = isFromMe ? String(localized: "Vous") : (cleaned(actor) ?? String(localized: "Quelqu’un"))
    let whom = cleaned(target)

    switch itemType {
    case 1:
      let verb = conjugated(actionType == 1 ? String(localized: "retiré") : String(localized: "ajouté"), isFromMe: isFromMe)
      return String(localized: "\(who) \(verb) \(whom ?? String(localized: "une personne"))")
    case 2:
      guard let title = cleaned(groupTitle) else {
        return String(localized: "\(who) \(conjugated(String(localized: "renommé"), isFromMe: isFromMe)) la conversation")
      }
      return String(localized: "\(who) \(conjugated(String(localized: "nommé"), isFromMe: isFromMe)) la conversation « \(title) »")
    case 3:
      // `group_action_type` 1 sur un `item_type` 3 = la photo du groupe a changé,
      // pas un départ : Messages range les deux sous le même type d'élément.
      return actionType == 1
        ? String(localized: "\(who) \(conjugated(String(localized: "changé"), isFromMe: isFromMe)) la photo de la conversation")
        : String(localized: "\(who) \(conjugated(String(localized: "quitté"), isFromMe: isFromMe)) la conversation")
    default:
      return nil
    }
  }

  /// « a ajouté » pour les autres, « avez ajouté » pour moi — les quatre verbes
  /// employés ici se conjuguent tous avec l'auxiliaire avoir.
  private static func conjugated(_ participle: String, isFromMe: Bool) -> String {
    isFromMe ? String(localized: "avez \(participle)") : String(localized: "a \(participle)")
  }

  private static func cleaned(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
