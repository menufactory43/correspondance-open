import Foundation

/// Ramène une adresse de n'importe quel réseau à une identité comparable.
///
/// Chaque transport écrit la même personne à sa façon : iMessage `+33612345678`
/// ou une adresse e-mail, Signal un E.164 ou un UUID de compte, WhatsApp un
/// ghost mautrix `@whatsapp_33612345678:serveur` (voire `whatsapp:33612345678`).
/// Fusionner suppose de savoir que ces trois écritures désignent le même numéro.
///
/// La règle est volontairement étroite : on ne rapproche que ce qui se compose
/// (un numéro) ou ce qui s'écrit (une adresse e-mail). Un UUID Signal ne dit
/// rien du numéro derrière — il ne produit aucune clé, donc aucune fusion.
enum PhoneNormalizer {
  /// Clé d'identité, ou `nil` quand l'adresse ne permet aucun rapprochement.
  /// Les clés sont préfixées (`tel:` / `email:`) pour qu'un numéro ne puisse
  /// jamais collisionner avec une adresse.
  static func identityKey(for raw: String) -> String? {
    var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }

    // MXID bridgé : `@whatsapp_33612345678:serveur` → on ne garde que la partie locale.
    if candidate.hasPrefix("@"), let colon = candidate.firstIndex(of: ":") {
      candidate = String(candidate[candidate.index(after: candidate.startIndex)..<colon])
    }

    // Préfixes de transport, tels qu'on les rencontre dans nos identifiants.
    for prefix in ["whatsapp:", "signal:", "imessage:", "tel:", "mailto:"]
    where candidate.lowercased().hasPrefix(prefix) {
      candidate = String(candidate.dropFirst(prefix.count))
    }

    // Partie locale d'un ghost mautrix : `whatsapp_33612345678`.
    if candidate.lowercased().hasPrefix("whatsapp_") {
      candidate = String(candidate.dropFirst("whatsapp_".count))
    }

    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }

    if candidate.contains("@") {
      let email = candidate.lowercased()
      // Une adresse sans domaine n'est pas une adresse : on ne fusionne pas dessus.
      guard let at = email.firstIndex(of: "@"), email[email.index(after: at)...].contains(".") else {
        return nil
      }
      return "email:" + email
    }

    if isUUID(candidate) { return nil }
    return phoneKey(candidate)
  }

  /// Numéro en E.164 sans `+`, ou `nil` si ce n'est pas composable.
  /// Un 0 initial à dix chiffres est lu comme un national français → `33`.
  static func phoneKey(_ raw: String) -> String? {
    // Une lettre au milieu (pseudo, identifiant de salon) disqualifie le numéro.
    let extraneous = raw.filter {
      !$0.isNumber && $0 != "+" && !$0.isWhitespace && $0 != "-" && $0 != "." && $0 != "(" && $0 != ")"
    }
    guard extraneous.isEmpty else { return nil }

    var digits = raw.filter(\.isNumber)
    guard digits.count >= 8 else { return nil }

    if digits.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
    if digits.hasPrefix("0"), digits.count == 10 { digits = "33" + digits.dropFirst() }
    guard digits.count >= 8 else { return nil }
    return "tel:" + digits
  }

  /// UUID nu — l'identifiant de compte Signal, qui ne se rapproche de rien.
  static func isUUID(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                options: .regularExpression) != nil
  }
}
