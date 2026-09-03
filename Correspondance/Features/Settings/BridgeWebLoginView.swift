import SwiftUI
import WebKit
import CorrespondanceCore

/// La fenêtre de connexion d'un réseau Meta, dans l'app.
///
/// Le pont ne sait se connecter qu'avec les cookies d'une session de navigateur : c'est
/// une contrainte de Meta, pas un choix. Plutôt que de demander à l'utilisateur d'aller
/// les pêcher dans les outils de développement, on lui montre le vrai formulaire —
/// instagram.com pour Instagram, facebook.com pour Messenger, identifiants, 2FA et
/// captcha compris — et on récolte la session à sa place.
///
/// Une seule vue pour les deux réseaux : c'est le profil (`BridgeSessionCookies.Profile`)
/// qui dit quelle page ouvrir et quels cookies font une session complète. La session n'est
/// livrée que quand celle du bon domaine est entière — un `datr` de facebook.com croisé
/// pendant une connexion Instagram ne déclenche rien.
///
/// Vie privée : magasin de données **non persistant** et dédié. On ne lit pas la session
/// Safari de l'utilisateur, on ne laisse rien sur le disque, et la session ne survit pas à
/// la fermeture de la feuille (elle a été transmise au pont, qui la garde de son côté).
/// Les cookies ne sont jamais journalisés : ils traversent la closure et repartent.
struct BridgeWebLoginView: NSViewRepresentable {
  /// Le réseau qu'on connecte — il décide de l'URL et de la validation.
  let network: MessageNetwork
  /// Appelée **une seule fois**, dès que la session est complète.
  let onSessionCookies: ([String: String]) -> Void

  /// Meta sert parfois une page dégradée (ou rien du tout) à un WebKit nu.
  /// On se présente comme le Safari du Mac, ce que la vue est de toute façon.
  private static let safariUserAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.6 Safari/605.1.15
    """

  /// Slack refuse Safari pour son app web (« votre navigateur n'est pas pris en
  /// charge ») : on se présente en Chrome, qu'il accepte. Sur une seule ligne —
  /// un `User-Agent` ne doit porter aucun retour à la ligne.
  private static let chromeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

  private var userAgent: String {
    network == .slack ? Self.chromeUserAgent : Self.safariUserAgent
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(network: network, profile: BridgeSessionCookies.Profile.of(network), onSessionCookies: onSessionCookies)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // Chrome se reconnaît aussi à `navigator.userAgentData` et au suffixe du UA :
    // on complète le UA nommé, pas seulement `customUserAgent`.
    if network == .slack {
      configuration.applicationNameForUserAgent = "Chrome/128.0.0.0"
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = userAgent
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.observe(webView)
    // Un réseau sans profil ne se connecte pas par session de navigateur : la vue
    // reste vide plutôt que d'ouvrir une page au hasard.
    if let url = BridgeSessionCookies.Profile.of(network)?.loginURL ?? (network == .slack ? SlackLoginSession.loginURL : nil) {
      webView.load(URLRequest(url: url))
    }
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.stopObserving()
  }

  /// Surveille la session : à chaque fin de navigation, et à intervalle régulier parce
  /// que les formulaires de Meta sont des SPA — se connecter n'y provoque pas forcément
  /// de navigation que WebKit nous signale.
  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let network: MessageNetwork
    private let profile: BridgeSessionCookies.Profile?
    private let onSessionCookies: ([String: String]) -> Void
    private weak var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    /// Garde-fou : la récolte est déclenchée de deux endroits, l'envoi n'a lieu qu'une fois.
    private var hasDelivered = false

    init(network: MessageNetwork, profile: BridgeSessionCookies.Profile?, onSessionCookies: @escaping ([String: String]) -> Void) {
      self.network = network
      self.profile = profile
      self.onSessionCookies = onSessionCookies
    }

    func observe(_ webView: WKWebView) {
      self.webView = webView
      pollTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(2))
          guard !Task.isCancelled else { return }
          await self?.harvestSession()
        }
      }
    }

    func stopObserving() {
      pollTask?.cancel()
      pollTask = nil
    }

    private func harvestSession() async {
      guard !hasDelivered, let webView else { return }
      if network == .slack {
        await harvestSlackSession(webView)
        return
      }
      guard let profile else { return }
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      guard let session = BridgeSessionCookies(httpCookies: cookies, profile: profile) else { return }
      hasDelivered = true
      stopObserving()
      onSessionCookies(session.values)
    }

    /// Slack tient sa session en deux endroits : le jeton `auth_token` dans le
    /// `localStorage` (lu par le JS du connecteur), le `cookie_token` dans le cookie
    /// `d`. On n'envoie que quand les deux sont là et bien formés.
    private func harvestSlackSession(_ webView: WKWebView) async {
      let authToken: String? = await withCheckedContinuation { continuation in
        webView.evaluateJavaScript(SlackLoginSession.extractAuthTokenJS) { value, _ in
          continuation.resume(returning: value as? String)
        }
      }
      guard let authToken else { return }
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      let cookieToken = cookies.first {
        $0.name == SlackLoginSession.cookieName
          && $0.domain.hasSuffix(SlackLoginSession.cookieDomain)
      }?.value
      guard let session = SlackLoginSession(authToken: authToken, cookieToken: cookieToken) else { return }
      hasDelivered = true
      stopObserving()
      onSessionCookies(session.values)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor [weak self] in await self?.harvestSession() }
    }

    /// Meta sème des `target="_blank"` (mot de passe oublié, aide). Une feuille
    /// modale ne peut pas ouvrir de fenêtre : on charge dans la même vue.
    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
    }
  }
}
