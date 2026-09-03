import Foundation

/// La session Slack telle que mautrix-slack l'attend, en deux morceaux de deux endroits.
///
/// Slack n'est pas un pur jeu de cookies, d'où ce type à part plutôt qu'un
/// `BridgeSessionCookies.Profile` : le jeton `auth_token` (`xoxc-…`) vit dans le
/// `localStorage` de la page — `localConfig_v2`, sous `teams[…].token` —, tandis que
/// le `cookie_token` (`xoxd-…`) est le cookie `d` de slack.com. Le flow `token` du
/// connecteur (`pkg/connector/login-cookie.go`) valide les deux par les motifs
/// `^xoxc-.+$` et `^xoxd-[a-zA-Z0-9/+=]+$` ; on les reprend, pour ne pas envoyer au
/// bot une session qu'il refusera.
///
/// Isolé de WebKit comme le reste : la fenêtre récolte le jeton et le cookie, mais
/// « cette session est-elle complète ? » et la mise en JSON se testent sans navigateur.
/// Rien n'est journalisé ni conservé : la valeur ne fait que traverser l'app.
public struct SlackLoginSession: Equatable, Sendable {
  public let authToken: String
  public let cookieToken: String

  /// La page qu'ouvre la fenêtre de connexion.
  public static let loginURL = URL(string: "https://slack.com/signin")!
  /// Domaine du cookie `d`.
  public static let cookieDomain = "slack.com"
  /// Le cookie qui porte le `cookie_token`.
  public static let cookieName = "d"

  /// Le JavaScript du connecteur, mot pour mot (`ExtractSlackTokenJS`) : il clique
  /// « Use Slack in Browser » si la page le propose, puis lit le jeton d'équipe dans
  /// `localConfig_v2`. On l'enveloppe d'une fonction pour l'évaluer dans la vue web ;
  /// il rend `{ auth_token }` quand le jeton est là, `null` tant qu'il ne l'est pas.
  public static let extractAuthTokenJS = """
    (function () {
      try {
        if (/\\.slack\\.com$/.test(window.location.host)) {
          const link = document?.querySelector?.(".p-ssb_redirect__body")?.querySelector?.(".c-link")
          if (link) { location.href = link.getAttribute("href") }
        }
        if (!localStorage.localConfig_v2 || !localStorage.localConfig_v2.includes("xoxc-")) { return null }
        const teams = JSON.parse(localStorage.localConfig_v2).teams
        const token = Object.values(teams)[0]?.token
        return token || null
      } catch (e) { return null }
    })()
    """

  /// `nil` tant que la session n'est pas complète et bien formée.
  public init?(authToken: String?, cookieToken: String?) {
    let auth = authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cookie = cookieToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard auth.hasPrefix("xoxc-"), auth.count > "xoxc-".count else { return nil }
    guard cookie.hasPrefix("xoxd-"), cookie.count > "xoxd-".count else { return nil }
    self.authToken = auth
    self.cookieToken = cookie
  }

  /// Depuis un objet collé à la main, ou reçu de la fenêtre. Accepte les deux clés
  /// que le connecteur nomme.
  public init?(values: [String: String]) {
    self.init(authToken: values["auth_token"], cookieToken: values["cookie_token"])
  }

  /// Depuis un collage : l'objet JSON, ou une commande cURL copiée depuis
  /// l'onglet Réseau des outils de développement — le jeton `xoxc-…` y est dans
  /// le corps (`token=`), le `xoxd-…` dans l'en-tête `cookie` (`d=`), encodé
  /// pour l'URL (`%2F`, `%2B`, `%3D`). Le bot sait lire un cURL dans le chat ;
  /// l'API de provisioning, elle, n'attend que les deux champs — on les extrait.
  public init?(pasted raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{"),
       let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: String]
    {
      self.init(values: object)
      return
    }
    guard let auth = Self.firstMatch(#"xoxc-[A-Za-z0-9-]+"#, in: trimmed),
          let cookieRaw = Self.firstMatch(#"xoxd-[A-Za-z0-9/+=%-]+"#, in: trimmed)
    else { return nil }
    self.init(authToken: auth, cookieToken: cookieRaw.removingPercentEncoding ?? cookieRaw)
  }

  private static func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text)
    else { return nil }
    return String(text[range])
  }

  public var values: [String: String] {
    ["auth_token": authToken, "cookie_token": cookieToken]
  }

  /// L'objet JSON attendu par le bot, clés triées pour être reproductible.
  public var jsonPayload: String {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  /// Le mode d'emploi du repli « coller la session », propre à Slack — le jeton n'est
  /// pas un cookie, on ne peut pas le prendre dans l'onglet Cookies.
  public static var manualStepsFR: [String] {
    [
      "Connecte-toi sur ton espace Slack dans ton navigateur (l’app web, pas l’app native).",
      "Ouvre les outils de développement : ⌥⌘I, ou Affichage › Développeur.",
      "Onglet Réseau. Recharge la page, clique une requête vers `slack.com/api/…`.",
      "Clic droit sur la requête › Copier › Copier comme cURL, et colle la commande entière ci-dessous.",
      "Ou, à la main : le jeton `auth_token` (`xoxc-…`) est dans Application › Local Storage › `localConfig_v2` ; le `cookie_token` (`xoxd-…`) est le cookie `d`.",
    ]
  }

  public static let manualTemplate = "{\"auth_token\":\"xoxc-…\",\"cookie_token\":\"xoxd-…\"}"
}
