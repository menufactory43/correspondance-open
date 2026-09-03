import Foundation

/// Détection des liens dans le corps d'un message : adresses web, e-mails, numéros.
///
/// Pur et sans SwiftUI : c'est la partie que les tests exercent. L'habillage
/// (couleur d'accent, soulignement) reste au thème, côté `Design/`.
public enum TextLinks {
  /// Une plage cliquable et sa destination.
  public struct Detected: Equatable, Sendable {
    public var range: Range<String.Index>
    public var url: URL
  }

  #if !canImport(Darwin)
  /// Sous Linux, pas de `NSDataDetector` : une expression régulière trouve les
  /// adresses web, les « www. », les e-mails et les numéros — moins fine que
  /// le détecteur d'Apple, mais suffisante pour rendre un lien cliquable.
  private static let motif = try! NSRegularExpression(
    pattern: #"(?i)\b(?:https?://[^\s<>"']+|www\.[^\s<>"']+|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\+?\d[\d .-]{5,}\d)"#
  )

  public static func detect(in text: String) -> [Detected] {
    guard !text.isEmpty else { return [] }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    return motif.matches(in: text, options: [], range: full).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      var raw = String(text[range])
      while let last = raw.last, ".,;:!?)".contains(last) { raw.removeLast() }
      guard let url = destination(raw: raw) else { return nil }
      return Detected(range: text.index(range.lowerBound, offsetBy: 0)..<text.index(range.lowerBound, offsetBy: raw.count), url: url)
    }
  }

  private static func destination(raw: String) -> URL? {
    if raw.contains("@") && !raw.contains("://") { return URL(string: "mailto:\(raw)") }
    if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
    if raw.lowercased().hasPrefix("www.") { return URL(string: "https://\(raw)") }
    let digits = raw.filter { $0.isNumber || $0 == "+" }
    guard digits.count >= 6 else { return nil }
    return URL(string: "tel:\(digits)")
  }
  #else
  /// `NSDataDetector` compile ses règles à la construction : une seule instance
  /// pour toute l'app, sinon chaque bulle repayerait l'addition à chaque rendu.
  private static let detector: NSDataDetector? = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
      | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
  )


  #endif

  #if canImport(Darwin)
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
  #endif

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
      #if canImport(Darwin)
      guard let bounds = Range(NSRange(link.range, in: text), in: attributed) else { continue }
      #else
      let start = text.distance(from: text.startIndex, to: link.range.lowerBound)
      let count = text.distance(from: link.range.lowerBound, to: link.range.upperBound)
      let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
      let bounds = lower..<attributed.index(lower, offsetByCharacters: count)
      #endif
      attributed[bounds].link = link.url
    }
    return attributed
  }

  #if canImport(Darwin)
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
  #endif
}
