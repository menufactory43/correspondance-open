import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// La session d'un réseau telle que son pont l'attend, extraite d'un jeu de cookies.
///
/// Instagram, Messenger et X se connectent de la même façon — ni Meta ni X n'offrent
/// autre chose que les cookies d'un navigateur — mais pas avec les mêmes clés ni sur
/// le même domaine. D'où un seul type et trois profils : un réseau de plus, c'est un
/// profil de plus, pas une nouvelle copie de ce fichier.
///
/// Isolé de WebKit exprès : la vue de connexion récolte des `HTTPCookie`, mais la
/// question « cette session est-elle complète ? » et la mise en forme du JSON se
/// testent sans navigateur, et se relisent sans ouvrir une `NSViewRepresentable`.
///
/// Rien n'est journalisé ni conservé ici : la valeur ne fait que traverser l'app,
/// de la fenêtre de connexion au salon de gestion du pont.
public struct BridgeSessionCookies: Equatable, Sendable {
  /// Ce qu'un réseau demande : où se connecter, quelles clés font une session.
  ///
  /// Les listes viennent du connecteur, pas de la doc : `pkg/messagix/cookies` de
  /// mautrix/meta déclare `IGRequiredCookies` et `FBRequiredCookies`, et c'est ce que
  /// `SubmitCookies` refuse quand il en manque une. La page docs.mau.fi diverge un peu
  /// (elle range `sb` du côté des indispensables) — c'est le code qui fait foi.
  public struct Profile: Equatable, Sendable {
    public let network: MessageNetwork
    /// La page qu'ouvre la fenêtre de connexion intégrée.
    public let loginURL: URL
    /// Sans celles-là, la session n'existe pas encore : l'utilisateur est sur le
    /// formulaire, ou au milieu d'une 2FA. C'est leur arrivée qui déclenche l'envoi.
    public let requiredNames: Set<String>
    /// Ce que le pont accepte en plus, sans jamais s'en formaliser.
    public let optionalNames: Set<String>
    /// Domaine dont on accepte les cookies. Un `csrftoken` pris ailleurs n'a rien à
    /// faire dans la charge utile.
    public let cookieDomain: String

    public init(network: MessageNetwork, loginURL: URL, requiredNames: Set<String>, optionalNames: Set<String>, cookieDomain: String) {
      self.network = network
      self.loginURL = loginURL
      self.requiredNames = requiredNames
      self.optionalNames = optionalNames
      self.cookieDomain = cookieDomain
    }

    /// Le mode d'emploi du repli « coller la session », étape par étape, tel que
    /// la feuille l'affiche. Écrit pour Brave et Chrome (mêmes outils, mêmes
    /// noms) ; Safari est nommé là où il diffère. Le JSON d'exemple ne porte que
    /// les clés obligatoires, dans l'ordre où le pont les lit.
    public var manualCookieStepsFR: [String] {
      let site = loginURL.host ?? cookieDomain
      let names = requiredNames.sorted().map { "`\($0)`" }
      let liste = names.count == 2
        ? names.joined(separator: " et ")
        : names.dropLast().joined(separator: ", ") + " et " + (names.last ?? "")
      return [
        "Connecte-toi sur \(site) dans ton navigateur (Brave, Chrome, Safari…).",
        "Ouvre les outils de développement : ⌥⌘I, ou Affichage › Développeur › Outils de développement.",
        "Onglet Application (s'il est caché, clique sur » dans la barre d'onglets). Dans Safari : onglet Stockage.",
        "Colonne de gauche : Storage › Cookies › https://\(cookieDomain).",
        "Dans le tableau, trouve les lignes \(liste). Double-clic sur la case Value pour la sélectionner en entier, puis copie.",
        "Colle les valeurs dans le champ ci-dessous, dans le modèle proposé, puis Envoyer.",
      ]
    }

    /// Le JSON à compléter : les clés obligatoires, valeurs vides.
    public var manualCookieTemplate: String {
      "{" + requiredNames.sorted().map { "\"\($0)\":\"…\"" }.joined(separator: ",") + "}"
    }

    /// Le domaine du cookie tombe-t-il sous celui du profil ? WebKit préfixe d'un point
    /// les cookies posés pour un domaine et ses sous-domaines : on l'enlève avant de comparer.
    public func acceptsDomain(_ domain: String) -> Bool {
      let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
      return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
    }

    public static let instagram = Profile(
      network: .instagram,
      loginURL: URL(string: "https://www.instagram.com/accounts/login/")!,
      requiredNames: ["sessionid", "ds_user_id", "csrftoken"],
      // `mid` et `ig_did` sont posés par instagram.com dès la première page ; `rur`,
      // `shbid` et `shbts` n'arrivent pas partout, et le bot ne s'en formalise pas.
      optionalNames: ["mid", "ig_did", "rur", "shbid", "shbts"],
      cookieDomain: "instagram.com"
    )

    /// Messenger se connecte sur **facebook.com**. Le pont expose deux flux web —
    /// `facebook` (cookies facebook.com) et `messenger` (cookies messenger.com) — et
    /// on a d'abord pris messenger.com, en pensant qu'il éviterait de retomber sur un
    /// autre profil. En pratique c'est l'inverse : messenger.com mure la connexion
    /// derrière une vérification en deux étapes qui échoue (« ce contenu n'est pas
    /// disponible »), tandis que la session Facebook du compte, elle, reste vivante sur
    /// facebook.com. C'est donc là qu'on récolte les cookies, avec le flux `facebook`.
    ///
    /// Trois cookies suffisent — `FBRequiredCookies` de `pkg/messagix/cookies` :
    /// `c_user` (l'identifiant du compte), `xs` (la session elle-même) et `datr`
    /// (l'empreinte du navigateur, sans laquelle Meta considère la session suspecte).
    public static let messenger = Profile(
      network: .messenger,
      loginURL: URL(string: "https://www.facebook.com/login/")!,
      requiredNames: ["c_user", "xs", "datr"],
      // Le pont ne déclare aucun cookie « optionnel » pour la famille Facebook, mais
      // facebook.com pose `wd` (taille de fenêtre), `sb`, `fr`… : on les laisse passer
      // s'ils sont là — ils sont rejoués tels quels dans l'en-tête `Cookie`, aucun ne bloque.
      optionalNames: ["sb", "fr", "presence", "wd", "oo", "dpr"],
      cookieDomain: "facebook.com"
    )

    /// X se connecte sur **x.com**, avec deux cookies et pas un de plus : `auth_token`
    /// (la session) et `ct0` (le jeton CSRF, que le pont rejoue en en-tête). Ce sont
    /// les deux champs `Required` du flow `cookies` de mautrix-twitter
    /// (`pkg/connector/login.go`) ; le bot refuse tout le reste par « Missing some
    /// keys » s'il en manque un, et ignore ce qu'il ne connaît pas.
    ///
    /// La page de connexion est `/i/flow/login`, celle que le pont lui-même nomme
    /// comme « Login URL ». La session se pose sur `.x.com` ; twitter.com, que la
    /// page peut encore traverser, n'a rien à y apporter.
    public static let twitter = Profile(
      network: .twitter,
      loginURL: URL(string: "https://x.com/i/flow/login")!,
      requiredNames: ["auth_token", "ct0"],
      optionalNames: [],
      cookieDomain: "x.com"
    )

    /// Profil d'un réseau, ou `nil` s'il ne se connecte pas par session de navigateur.
    public static func of(_ network: MessageNetwork) -> Profile? {
      switch network {
      case .instagram: .instagram
      case .messenger: .messenger
      case .twitter: .twitter
      case .iMessage, .signal, .whatsapp, .selfNote, .agent: nil
      }
    }
  }

  public let profile: Profile
  /// Uniquement les cookies que le pont sait lire, les autres sont écartés.
  public let values: [String: String]

  /// `nil` tant que la session n'est pas complète — appeler ne coûte rien, et évite
  /// à l'appelant de retenir la liste des clés.
  public init?(rawCookies: [String: String], profile: Profile) {
    var kept: [String: String] = [:]
    for (name, value) in rawCookies where !value.isEmpty {
      guard profile.requiredNames.contains(name) || profile.optionalNames.contains(name) else { continue }
      kept[name] = value
    }
    guard profile.requiredNames.isSubset(of: Set(kept.keys)) else { return nil }
    self.profile = profile
    values = kept
  }

  /// Depuis le magasin de cookies du navigateur intégré. Seul le domaine du profil
  /// est retenu : la fenêtre traverse d'autres sites au passage (captcha, aide).
  public init?(httpCookies: [HTTPCookie], profile: Profile) {
    var raw: [String: String] = [:]
    for cookie in httpCookies where profile.acceptsDomain(cookie.domain) {
      raw[cookie.name] = cookie.value
    }
    self.init(rawCookies: raw, profile: profile)
  }

  /// L'objet JSON attendu par le pont, clés triées pour être reproductible.
  public var jsonPayload: String {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
