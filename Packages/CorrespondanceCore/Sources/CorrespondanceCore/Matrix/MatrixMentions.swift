import Foundation

/// L'AROBASE PERDUE DES MENTIONS BRIDGÉES.
///
/// Quand quelqu'un mentionne trois personnes sur Signal ou WhatsApp, mautrix
/// n'écrit pas « @Azer » dans le corps du message : il y pose le NOM SEUL et
/// range l'arobase dans la pilule HTML de `formatted_body` —
/// `<a href="https://matrix.to/#/@signal_…">Azer</a>`. Notre bulle ne lisait
/// que le corps : « Salut les gars @21 Rue des Satochis @Azer @François »
/// arrivait « Salut les gars 21 Rue des Satochis Azer François », les mentions
/// fondues dans la phrase.
///
/// On rend donc son arobase à chaque pilule — dans le corps nu, celui que tous
/// les réseaux transportent et que le reste de l'app sait déjà lire.
public enum MatrixMentions {
  /// Le corps, ses mentions rendues visibles. Sans pilule (message ordinaire,
  /// réseau qui n'en pose pas), le corps ressort intact.
  public static func restoringPills(in body: String, formattedBody: String?) -> String {
    guard let formattedBody, !body.isEmpty else { return body }
    let names = pillNames(in: formattedBody)
    guard !names.isEmpty else { return body }

    // Une pilule, une occurrence : le même nom mentionné deux fois prend deux
    // arobases, et un nom qui traîne aussi dans la phrase n'en prend pas.
    var marks: [String.Index] = []
    var taken: [Range<String.Index>] = []
    for name in names {
      guard let range = firstMention(of: name, in: body, skipping: taken) else { continue }
      taken.append(range)
      marks.append(range.lowerBound)
    }
    guard !marks.isEmpty else { return body }

    var result = body
    // De la fin vers le début : insérer devant ne déplace pas ce qui précède.
    for index in marks.sorted(by: >) {
      result.insert("@", at: index)
    }
    return result
  }

  /// Le texte des pilules qui désignent QUELQU'UN, dans l'ordre du message. La
  /// citation (`<mx-reply>`) est écartée d'abord : ses pilules à elle parlent
  /// du message cité, pas de celui-ci.
  public static func pillNames(in formattedBody: String) -> [String] {
    let html = strippingReply(formattedBody)
    guard let regex = Self.pill else { return [] }
    let full = NSRange(html.startIndex..<html.endIndex, in: html)
    return regex.matches(in: html, options: [], range: full).compactMap { match in
      guard let range = Range(match.range(at: 1), in: html) else { return nil }
      let name = unescaped(String(html[range])).trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }
  }

  /// `<a href="https://matrix.to/#/@quelqu-un:serveur">Nom</a>` — seulement un
  /// utilisateur : une pilule de salon (`!`, `#`) n'est pas une mention de personne.
  private static let pill = try? NSRegularExpression(
    pattern: #"<a\s[^>]*href="https://matrix\.to/#/@[^"]*"[^>]*>([^<]*)</a>"#,
    options: [.caseInsensitive]
  )

  private static func strippingReply(_ html: String) -> String {
    guard let start = html.range(of: "<mx-reply>", options: .caseInsensitive),
          let end = html.range(of: "</mx-reply>", options: .caseInsensitive)
    else { return html }
    var out = html
    out.removeSubrange(start.lowerBound..<end.upperBound)
    return out
  }

  /// La première occurrence du nom qui puisse être une mention : un mot entier,
  /// pas déjà précédé d'une arobase, et pas une occurrence déjà prise.
  private static func firstMention(
    of name: String, in body: String, skipping taken: [Range<String.Index>]
  ) -> Range<String.Index>? {
    var searchStart = body.startIndex
    while let range = body.range(of: name, range: searchStart..<body.endIndex) {
      searchStart = body.index(after: range.lowerBound)
      if taken.contains(where: { $0.overlaps(range) }) { continue }
      if range.lowerBound > body.startIndex {
        let before = body[body.index(before: range.lowerBound)]
        // Déjà son arobase (un pont qui la garde), ou un mot qui n'est pas fini.
        if before == "@" || before.isLetter || before.isNumber { continue }
      }
      if range.upperBound < body.endIndex {
        let after = body[range.upperBound]
        if after.isLetter || after.isNumber { continue }
      }
      return range
    }
    return nil
  }

  private static func unescaped(_ value: String) -> String {
    var out = value
    for (entity, character) in [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
      ("&nbsp;", " "), ("&amp;", "&"),
    ] {
      out = out.replacingOccurrences(of: entity, with: character)
    }
    return out
  }
}
