import Foundation

/// UN POST PARTAGÉ DEPUIS INSTAGRAM, tel que le pont mautrix-meta le livre :
/// un texte en Markdown — l'auteur et la légende en gras, puis un lien nommé
/// vers `instagram.com/reel/…` — et le média du post en pièce jointe.
///
/// Rendu tel quel, ça donne des astérisques, des crochets et l'adresse écrite
/// deux fois, avec un lecteur vidéo qui joue le reel hors d'Instagram. La
/// bulle en fait une carte : la vignette, l'auteur, la légende, et tout
/// l'ensemble ouvre le post là où il vit.
public struct SharedPost: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case reel
    case post
    case story
  }

  public let url: URL
  public let kind: Kind
  public let author: String?
  public let caption: String?
  /// La vidéo du reel ou la vignette du post, quand le pont l'a jointe.
  /// Modifiable : les vues y remettent le chemin local qu'elles retrouvent en cache.
  public var media: MessageAttachment?

  /// Ce que la liste des fils annonce à la place du Markdown brut.
  public var previewText: String {
    switch (kind, author) {
    case (.reel, let author?): "Reel de \(author)"
    case (.reel, nil): "Reel Instagram"
    case (.story, _): "Story Instagram"
    case (.post, _): "Publication Instagram"
    }
  }

  /// Le partage que porte ce message, ou `nil` si c'en est un ordinaire.
  ///
  /// Exigeant à dessein : le texte doit se réduire au gras optionnel et au lien
  /// Markdown, et le message ne porter qu'un média au plus. Une phrase écrite
  /// autour d'un lien Instagram reste une phrase, avec sa bulle et son aperçu.
  public static func parse(_ message: ChatMessage) -> SharedPost? {
    guard message.attachments.count <= 1, message.poll == nil, !message.isRetracted else { return nil }
    guard let parsed = parse(text: message.text) else { return nil }
    return SharedPost(
      url: parsed.url,
      kind: parsed.kind,
      author: parsed.author,
      caption: parsed.caption,
      media: message.attachments.first
    )
  }

  /// La forme du texte seule — c'est elle qu'on teste.
  public static func parse(text: String)
    -> (url: URL, kind: Kind, author: String?, caption: String?)?
  {
    // Garde bon marché : `sidebarPreviewText` passe ici pour chaque ligne de l'inbox.
    guard text.contains("instagram.com/"), text.contains("](") else { return nil }

    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var author: String?
    var caption: String?

    if rest.hasPrefix("**"), let close = rest.range(of: "**", range: rest.index(rest.startIndex, offsetBy: 2)..<rest.endIndex) {
      let bold = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound])
      // Le pont colle « auteur » et « légende » dans le même gras, séparés d'une
      // espace : le premier mot est le compte, le reste ce qu'il a écrit.
      let parts = bold.split(separator: " ", maxSplits: 1).map(String.init)
      author = parts.first.flatMap { $0.isEmpty ? nil : $0 }
      caption = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
      rest = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let open = rest.firstIndex(of: "["),
          let labelEnd = rest.range(of: "](", range: open..<rest.endIndex),
          let close = rest[labelEnd.upperBound...].firstIndex(of: ")")
    else { return nil }
    // Rien avant ni après le lien : sinon c'est un message qui cite un post,
    // pas un post partagé.
    guard rest[rest.startIndex..<open].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          rest[rest.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    let target = String(rest[labelEnd.upperBound..<close])
    guard let (url, kind) = shortURL(target) else { return nil }
    return (url, kind, author, caption?.isEmpty == true ? nil : caption)
  }

  /// L'adresse du post débarrassée de la traîne de paramètres du pont
  /// (`?id=…&is_sponsored=…`), qui ne sert qu'à Instagram.
  private static func shortURL(_ raw: String) -> (URL, Kind)? {
    guard var components = URLComponents(string: raw),
          let host = components.host?.lowercased(),
          host == "instagram.com" || host.hasSuffix(".instagram.com")
    else { return nil }
    let kind: Kind? = switch components.path.split(separator: "/").first {
    case "reel", "reels": .reel
    case "p": .post
    case "stories": .story
    default: nil
    }
    guard let kind else { return nil }
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return nil }
    return (url, kind)
  }
}
