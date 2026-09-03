import Foundation

/// Ce qu'on sait d'une adresse, une fois la page interrogée : de quoi écrire
/// une carte sobre. Volontairement maigre — un aperçu n'est pas un navigateur.
public struct LinkPreview: Codable, Equatable, Sendable {
  public var title: String?
  /// Le domaine, sans « www. » : c'est lui qui dit où l'on va.
  public var domain: String
  /// Chemin de la vignette déjà réduite, quand la page en offrait une.
  public var imagePath: String?

  public var hasSomethingToShow: Bool {
    !(title ?? "").isEmpty || imagePath != nil
  }

  /// Le domaine tel qu'on l'écrit sous le titre : « lemonde.fr », pas
  /// « www.lemonde.fr » — le « www. » n'apprend rien à personne.
  public static func domain(of url: URL) -> String {
    let host = url.host ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  public init(title: String?, domain: String, imagePath: String?) {
    self.title = title
    self.domain = domain
    self.imagePath = imagePath
  }
}
