import SwiftUI
import WebKit
import CorrespondanceCore

/// Une étape « cookies » de l'API de provisioning, rendue : la page que le pont
/// nomme, et son JavaScript d'extraction évalué dedans.
///
/// C'est le mécanisme de Beeper. Le pont ne dit pas « va chercher tel cookie » :
/// il donne une URL et un script qui s'évalue en une promesse, résolue avec les
/// champs qu'il attend. Pour le captcha de Slack, le script pose un reCAPTCHA
/// par-dessus `slack.com/signin` et se résout avec le `captcha_token` quand
/// l'utilisateur l'a passé. Pour le flow `token`, il guette `localConfig_v2` dans
/// le `localStorage` et rend l'`auth_token`. Ce que le script ne rend pas se lit
/// dans les cookies de la vue, selon les `sources` de l'étape (le cookie `d`).
///
/// Vie privée : magasin **non persistant** et dédié, rien sur le disque, rien
/// dans le journal. Les valeurs traversent la closure et repartent au pont.
struct BridgeExtractionWebView: NSViewRepresentable {
  let params: BridgeLoginProcessStep.CookiesParams
  /// Appelée **une seule fois**, avec tous les champs obligatoires.
  let onValues: ([String: String]) -> Void
  /// Le script a échoué (page changée, reCAPTCHA refusé) : on le dit, et la
  /// prochaine fin de chargement le relancera.
  let onError: (String) -> Void
  /// Retouche du script avant évaluation — le mettre en français, par exemple.
  var scriptTransform: (String) -> String = { $0 }

  /// Slack refuse Safari pour son app web : on se présente en Chrome, qu'il
  /// accepte, quand le pont ne nomme pas d'agent. Sur une seule ligne.
  private static let chromeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

  func makeCoordinator() -> Coordinator {
    Coordinator(params: params, scriptTransform: scriptTransform, onValues: onValues, onError: onError)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let userAgent = params.userAgent.flatMap { $0.isEmpty ? nil : $0 } ?? Self.chromeUserAgent
    if userAgent.contains("Chrome/") {
      configuration.applicationNameForUserAgent = "Chrome/128.0.0.0"
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = userAgent
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.webView = webView
    if let url = URL(string: params.url) {
      webView.load(URLRequest(url: url))
    }
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.hasDelivered = true
    nsView.stopLoading()
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let params: BridgeLoginProcessStep.CookiesParams
    private let scriptTransform: (String) -> String
    private let onValues: ([String: String]) -> Void
    private let onError: (String) -> Void
    weak var webView: WKWebView?
    /// Le script est en cours : une fin de chargement de plus ne le relance pas.
    private var isExtracting = false
    var hasDelivered = false

    init(
      params: BridgeLoginProcessStep.CookiesParams,
      scriptTransform: @escaping (String) -> String,
      onValues: @escaping ([String: String]) -> Void,
      onError: @escaping (String) -> Void
    ) {
      self.params = params
      self.scriptTransform = scriptTransform
      self.onValues = onValues
      self.onError = onError
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor [weak self] in await self?.extract() }
    }

    private func extract() async {
      guard !hasDelivered, !isExtracting, let webView else { return }
      var values: [String: String] = [:]
      if let script = params.extractJS, !script.isEmpty {
        isExtracting = true
        defer { isExtracting = false }
        // Le script s'évalue en une promesse : dans le corps d'une fonction
        // asynchrone, `return await (…)` attend sa résolution.
        let body = "return await (\n\(scriptTransform(script))\n);"
        do {
          let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
          if let object = result as? [String: Any] {
            for (key, value) in object {
              if let text = value as? String { values[key] = text }
            }
          }
        } catch {
          guard !hasDelivered else { return }
          onError(error.localizedDescription)
          return
        }
      }
      guard !hasDelivered else { return }
      // Ce que le script n'a pas rendu se lit dans les cookies de la vue.
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      for field in params.cookieBackedFields where values[field.id] == nil {
        if let cookie = cookies.first(where: { cookie in
          cookie.name == field.cookieName
            && (field.domain.map { cookie.domain.hasSuffix($0) } ?? true)
        }) {
          values[field.id] = cookie.value
        }
      }
      let missing = params.requiredFieldIDs.filter { values[$0] == nil }
      guard missing.isEmpty else {
        onError("Il manque encore : \(missing.joined(separator: ", ")).")
        return
      }
      hasDelivered = true
      onValues(values)
    }

    /// Les `target="_blank"` s'ouvrent dans la même vue : une fenêtre de
    /// connexion n'en ouvre pas d'autre.
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
