import Foundation

/// Détection des liens dans le corps d'un message : adresses web, e-mails, numéros.
///
/// Pur et sans SwiftUI : c'est la partie que les tests exercent. L'habillage
/// (couleur d'accent, soulignement) reste au thème, côté `Design/`.
public enum TextLinks {
  /// `NSDataDetector` compile ses règles à la construction : une seule instance
  /// pour toute l'app, sinon chaque bulle repayerait l'addition à chaque rendu.
  private static let detector: NSDataDetector? = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
      | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
  )

  /// Une plage cliquable et sa destination.
  public struct Detected: Equatable, Sendable {
    public var range: Range<String.Index>
    public var url: URL
  }

  public static func detect(in text: String) -> [Detected] {
    guard !text.isEmpty, let detector else { return [] }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    return detector.matches(in: text, options: [], range: full).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      let raw = String(text[range])
      guard let url = destination(for: match, raw: raw) else { return nil }
      return Detected(range: range, url: url)
    }
  }

  /// LA PREMIÈRE ADRESSE WEB du message — celle dont on ira chercher l'aperçu.
  ///
  /// Une seule carte par bulle : un message qui aligne cinq liens en ferait un
  /// mur. Et seulement `http`/`https` — un `tel:` ou un `mailto:` n'a pas de
  /// page à montrer.
  public static func firstWebURL(in text: String) -> URL? {
    detect(in: text).first { link in
      let scheme = link.url.scheme?.lowercased()
      return scheme == "http" || scheme == "https"
    }?.url
  }

  /// `AttributedString` du texte, attribut `.link` posé sur les plages détectées.
  /// Le reste des attributs (police, encre) vient de la vue qui l'affiche.
  public static func linkified(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    for link in detect(in: text) {
      guard let bounds = Range(NSRange(link.range, in: text), in: attributed) else { continue }
      attributed[bounds].link = link.url
    }
    return attributed
  }

  private static func destination(for match: NSTextCheckingResult, raw: String) -> URL? {
    if match.resultType == .phoneNumber {
      // `tel:` n'accepte ni espaces ni ponctuation de mise en forme.
      let digits = (match.phoneNumber ?? raw).filter { $0.isNumber || $0 == "+" }
      guard digits.count >= 6 else { return nil }
      return URL(string: "tel:\(digits)")
    }
    // Un e-mail nu ressort déjà en `mailto:` chez le détecteur.
    if let url = match.url, url.scheme == "mailto" { return url }
    // « www.exemple.fr » : le détecteur propose `http://`. On ne dégrade personne
    // en clair — le web par défaut, aujourd'hui, c'est `https://`.
    if !raw.contains("://") {
      return URL(string: "https://\(raw)") ?? match.url
    }
    return match.url
  }
}
