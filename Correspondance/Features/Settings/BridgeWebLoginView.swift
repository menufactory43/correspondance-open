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

  func makeCoordinator() -> Coordinator {
    Coordinator(profile: BridgeSessionCookies.Profile.of(network), onSessionCookies: onSessionCookies)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = Self.safariUserAgent
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.observe(webView)
    // Un réseau sans profil ne se connecte pas par session de navigateur : la vue
    // reste vide plutôt que d'ouvrir une page au hasard.
    if let url = BridgeSessionCookies.Profile.of(network)?.loginURL {
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
    private let profile: BridgeSessionCookies.Profile?
    private let onSessionCookies: ([String: String]) -> Void
    private weak var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    /// Garde-fou : la récolte est déclenchée de deux endroits, l'envoi n'a lieu qu'une fois.
    private var hasDelivered = false

    init(profile: BridgeSessionCookies.Profile?, onSessionCookies: @escaping ([String: String]) -> Void) {
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
      guard !hasDelivered, let profile, let webView else { return }
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      guard let session = BridgeSessionCookies(httpCookies: cookies, profile: profile) else { return }
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
