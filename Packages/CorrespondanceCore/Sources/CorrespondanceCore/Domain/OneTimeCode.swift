import Foundation

/// Reconnaître un code à usage unique dans un message.
///
/// Un code de vérification a une durée de vie de trente secondes : le
/// regrouper avec la rafale qui le suit, c'est le rendre inutile. C'est la
/// seule exception au regroupement des notifications — d'où une décision
/// isolée ici, pure et testée, plutôt qu'une condition perdue dans le service.
///
/// Un faux positif ne coûte qu'une notification qui sonne tout de suite au
/// lieu d'attendre : on préfère donc large. Un faux négatif, lui, coûte un
/// code qu'on lit trop tard.
public enum OneTimeCode {
  /// Les mots qui annoncent un code, sans accent ni casse (cf. `fold`).
  private static let keywords = [
    "code", "verification", "verifier", "otp", "2fa",
    "authentification", "identification", "usage unique", "one-time", "one time",
    "mot de passe temporaire", "securite",
  ]

  public static func looksLikeCode(_ text: String) -> Bool {
    let folded = fold(text)
    guard !folded.isEmpty else { return false }
    if keywords.contains(where: { folded.contains($0) }) { return true }
    return containsIsolatedDigitRun(folded)
  }

  /// Un groupe de 4 à 8 chiffres qui ne touche ni lettre ni autre chiffre.
  /// « 123456 » oui ; « 12 » non ; « A1B2C3 » non ; « 0612345678 » non plus —
  /// dix chiffres, c'est un numéro de téléphone.
  private static func containsIsolatedDigitRun(_ folded: String) -> Bool {
    var run = 0
    var touchesLetter = false
    var found = false
    func close() {
      if run >= 4, run <= 8, !touchesLetter { found = true }
      run = 0
      touchesLetter = false
    }
    for character in folded {
      if character.isNumber {
        run += 1
      } else if character.isLetter {
        // Une lettre COLLÉE au groupe le disqualifie : « salle 1024b » n'est
        // pas un code, et le groupe suivant ne doit pas hériter du soupçon.
        if run > 0 { touchesLetter = true }
        close()
        touchesLetter = true
      } else {
        close()
      }
      if found { return true }
    }
    close()
    return found
  }

  /// Minuscules, sans accents : « Vérification » et « verification » sont le
  /// même mot pour qui cherche un code.
  private static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
  }
}
