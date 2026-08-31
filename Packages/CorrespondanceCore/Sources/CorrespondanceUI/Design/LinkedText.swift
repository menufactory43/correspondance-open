import SwiftUI
import CorrespondanceCore

/// Le corps d'un message, liens compris. `Text(AttributedString)` suffit :
/// sur macOS, SwiftUI confie l'attribut `.link` à `openURL`.
public struct LinkedText: View {
  public let text: String
  /// Couleur des liens — celle du thème, jamais le bleu système : il tranche sur
  /// les six papiers et devient illisible sur les sombres.
  public var tint: Color

  public var body: some View {
    Text(LinkedText.render(text: text, tint: tint))
  }

  /// Pose liens, couleur et soulignement sur `base` (ou sur le texte nu).
  /// `base` sert au surlignage ⌘F : il porte déjà le même contenu, autrement attribué.
  @MainActor
  public static func render(text: String, tint: Color, base: AttributedString? = nil) -> AttributedString {
    var attributed = base ?? AttributedString(text)
    for link in detected(in: text) {
      guard let bounds = Range(NSRange(link.range, in: text), in: attributed) else { continue }
      attributed[bounds].link = link.url
      attributed[bounds].foregroundColor = tint
      attributed[bounds].underlineStyle = .single
    }
    return attributed
  }

  /// La première adresse web du message, via le même mémo que le rendu : la
  /// carte d'aperçu ne relance pas le détecteur que la bulle vient de payer.
  @MainActor
  public static func firstWebURL(in text: String) -> URL? {
    detected(in: text).first { link in
      let scheme = link.url.scheme?.lowercased()
      return scheme == "http" || scheme == "https"
    }?.url
  }

  /// `NSDataDetector` coûte cher et une bulle se redessine à chaque frappe dans le
  /// composer : on garde les plages trouvées, indexées par le texte lui-même.
  @MainActor private static var memo: [String: [TextLinks.Detected]] = [:]

  @MainActor
  private static func detected(in text: String) -> [TextLinks.Detected] {
    if let hit = memo[text] { return hit }
    let found = TextLinks.detect(in: text)
    // Borne grossière : un fil très long ne doit pas faire grossir la mémoire sans fin.
    if memo.count > 2_000 { memo.removeAll(keepingCapacity: true) }
    memo[text] = found
    return found
  }

  public init(text: String, tint: Color) {
    self.text = text
    self.tint = tint
  }
}
