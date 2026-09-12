import Foundation

/// Ce qui, dans un message, s'adresse à MOI en particulier — fonction pure,
/// testée, sans Matrix ni SwiftUI.
///
/// Un fil muet ne notifie plus, sauf de ça : être nommé, ou se voir répondre.
/// C'est la règle de Signal, de WhatsApp et de Slack, et c'est aussi celle de
/// Matrix, dont les règles de mention (`override`, `content`) priment sur la
/// règle de salon qui porte la sourdine.
public enum PersonalMessage {
  /// Le texte me nomme-t-il ?
  ///
  /// Comparaison sur un mot entier, sans accent ni casse : « Lucas » dans
  /// « Lucastin » ne me nomme pas, et « lucas » si. C'est ce que fait la
  /// règle `.m.rule.contains_display_name` de Matrix, à ceci près qu'elle ne
  /// replie pas les accents — là où les ponts, eux, livrent le nom tel que le
  /// réseau d'origine l'écrit.
  public static func mentions(_ text: String, names: [String]) -> Bool {
    let haystack = fold(text)
    guard !haystack.isEmpty else { return false }
    for name in names {
      let needle = fold(name)
      // Un nom d'une seule lettre ne fait pas une mention : trop de faux.
      guard needle.count >= 2 else { continue }
      if contains(needle, inFolded: haystack) { return true }
    }
    return false
  }

  /// Vrai quand `needle` paraît dans `haystack` en mot entier — un « @ » collé
  /// devant compte comme une limite, c'est même la façon ordinaire d'écrire.
  private static func contains(_ needle: String, inFolded haystack: String) -> Bool {
    var search = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: search) {
      let beforeOK = found.lowerBound == haystack.startIndex
        || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
      let afterOK = found.upperBound == haystack.endIndex
        || !isWordCharacter(haystack[found.upperBound])
      if beforeOK && afterOK { return true }
      guard found.upperBound < haystack.endIndex else { return false }
      search = found.upperBound..<haystack.endIndex
    }
    return false
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  /// Sans accent, sans casse : la comparaison se fait sur le fond, pas sur
  /// l'orthographe qu'un pont a choisie.
  private static func fold(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Les noms sous lesquels on peut me désigner : mon nom affiché dans ce
  /// salon, et la partie locale de mon identifiant Matrix.
  ///
  /// La partie locale seulement quand elle ressemble à un nom : un identifiant
  /// technique (`whatsapp_lid-1234`) ne se dit pas à l'oral, et le chercher
  /// dans un texte ne donnerait que des faux.
  public static func names(displayName: String?, userLocalpart: String) -> [String] {
    var names: [String] = []
    if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      names.append(displayName)
      // « Lucas Dupont » se dit aussi « Lucas ».
      if let first = displayName.split(separator: " ").first, first.count >= 3 {
        names.append(String(first))
      }
    }
    if userLocalpart.count >= 3, userLocalpart.allSatisfy({ $0.isLetter || $0.isNumber }) {
      names.append(userLocalpart)
    }
    return names
  }
}
