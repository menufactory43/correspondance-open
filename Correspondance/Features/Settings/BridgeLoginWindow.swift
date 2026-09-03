import SwiftUI
import AppKit
import CorrespondanceCore
import CorrespondanceUI

/// La fenêtre « Connecter <réseau> » : ce que le pont demande, et rien d'autre.
///
/// WhatsApp et Signal font scanner un QR. Instagram, Messenger et X ne connaissent
/// que la session d'un navigateur : on montre leur vrai formulaire dans une vue web
/// qui prend toute la fenêtre, et on récolte la session à la place de l'utilisateur.
/// Quand le formulaire ne suffit pas — une passkey, qu'une WKWebView ne sait pas
/// ouvrir —, la barre du bas offre deux autres portes : lire la session dans Brave
/// ou Chrome (un clic, l'accord du Trousseau), ou la coller à la main. X demande
/// ensuite son code PIN : le formulaire cède la place à un champ de quatre chiffres.
///
/// Une `Window` et non une feuille : le formulaire de X tient mal dans 360 points,
/// et une fenêtre se redimensionne, se déplace, reste ouverte pendant qu'on va
/// chercher un code dans une autre app.
struct BridgeLoginWindow: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var cookies = ""
  @State private var passcode = ""
  @State private var showsManualCookies = false
  @State private var browsers: [InstalledBrowser] = []

  private var theme: WritingTheme { themes.theme }
  private var network: MessageNetwork? { store.bridgeLoginNetwork }
  private var flow: MatrixBridgeDescriptor.LoginFlow { network?.bridge?.loginFlow ?? .qrCode }

  var body: some View {
    Group {
      if let network {
        content(for: network)
      } else {
        // La fenêtre restaurée par le système au lancement : rien à connecter.
        // On le dit plutôt que de la fermer d'autorité — fermer ici pendant que
        // le réseau se pose ferait disparaître la fenêtre qu'on vient d'ouvrir.
        Text("Rien à connecter. Passe par Réglages › Comptes.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
      }
    }
    .frame(minWidth: 640, minHeight: 520)
    .background(theme.paper)
    .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
    .tint(theme.accent)
    .onAppear { browsers = BrowserSessionImporter.installed() }
    .onChange(of: store.bridgeLoginNetwork) { _, value in
      if value == nil { dismissWindow(id: WindowOpener.bridgeLoginSceneID) }
    }
    .onDisappear {
      store.stopBridgeLoginPolling()
      store.bridgeLoginNetwork = nil
      store.bridgeLoginPasscodePrompt = nil
    }
  }

  @ViewBuilder
  private func content(for network: MessageNetwork) -> some View {
    VStack(spacing: 0) {
      header(for: network)

      Group {
        switch flow {
        case .qrCode:
          qrCodePanel(for: network)
        case .webSession:
          if let prompt = store.bridgeLoginPasscodePrompt {
            passcodePanel(prompt)
          } else if showsManualCookies {
            manualCookiesPanel(for: network)
          } else {
            webPanel(for: network)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      footer(for: network)
    }
  }

  // MARK: - En-tête et pied

  private func header(for network: MessageNetwork) -> some View {
    VStack(spacing: 4) {
      Text("Connecter \(network.labelFR)")
        .font(Typography.letterHeading(themes.typeface))
        .foregroundStyle(theme.ink)
      Text(subtitle(for: network))
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
    }
    .padding(.top, Spacing.lg)
    .padding(.bottom, Spacing.md)
    .padding(.horizontal, Spacing.lg)
  }

  private func subtitle(for network: MessageNetwork) -> String {
    switch flow {
    case .qrCode:
      "Comme un nouveau téléphone : scanne le code depuis \(network.labelFR), dans Appareils liés."
    case .webSession:
      network == .twitter
        ? "Connecte-toi comme sur x.com. Si ton compte a une passkey, passe par ton navigateur, en bas."
        : "Connecte-toi comme sur le site : identifiants, code à deux facteurs, tout se passe ici."
    }
  }

  private func footer(for network: MessageNetwork) -> some View {
    VStack(spacing: Spacing.sm) {
      Text(store.bridgeLoginStatusFR)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)

      HStack(spacing: Spacing.sm) {
        if flow == .webSession, store.bridgeLoginPasscodePrompt == nil {
          if !browsers.isEmpty {
            browserImportMenu(for: network)
          }
          if let url = BridgeSessionCookies.Profile.of(network)?.loginURL {
            Button("Ouvrir dans le navigateur") { NSWorkspace.shared.open(url) }
              .help("Ouvre la page de connexion dans ton navigateur habituel. Reviens ensuite ici pour importer ou coller la session.")
          }
          Toggle(isOn: $showsManualCookies) { Text("Coller la session") }
            .toggleStyle(.button)
        }
        Spacer()
        Button("Relancer") { store.presentBridgeLogin(network: network) }
          .disabled(store.bridgeLoginImportBusy)
        Button("Fermer") { dismissWindow(id: WindowOpener.bridgeLoginSceneID) }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(Spacing.md)
    .padding(.horizontal, Spacing.xs)
    .background(theme.sidebar)
    .overlay(alignment: .top) { Rectangle().fill(theme.edge.opacity(0.4)).frame(height: 0.5) }
  }

  /// « Importer depuis Brave » — un bouton par navigateur trouvé, dans un menu
  /// s'il y en a plusieurs. C'est la porte des comptes à passkey.
  @ViewBuilder
  private func browserImportMenu(for network: MessageNetwork) -> some View {
    if browsers.count == 1, let browser = browsers.first {
      Button("Importer depuis \(browser.name)") {
        store.importBrowserSession(from: browser, network: network)
      }
      .disabled(store.bridgeLoginImportBusy)
      .help("Lit ta session \(network.labelFR) dans \(browser.name). macOS demandera ton accord pour la clé du Trousseau.")
    } else {
      Menu("Importer depuis…") {
        ForEach(browsers) { browser in
          Button(browser.name) { store.importBrowserSession(from: browser, network: network) }
        }
      }
      .disabled(store.bridgeLoginImportBusy)
      .fixedSize()
    }
  }

  // MARK: - QR (WhatsApp, Signal)

  private func qrCodePanel(for network: MessageNetwork) -> some View {
    VStack(spacing: Spacing.md) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.white)
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
          )
        if let data = store.bridgeLoginQRData, let image = NSImage(data: data) {
          Image(nsImage: image)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .padding(Spacing.sm)
        } else {
          ProgressView()
        }
      }
      .frame(width: 320, height: 320)

      if let code = store.bridgeLoginPairingCode {
        Text(code)
          .font(.system(size: 26, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.ink)
          .textSelection(.enabled)
      }
    }
    .padding(Spacing.lg)
  }

  // MARK: - Formulaire du site (Instagram, Messenger, X)

  private func webPanel(for network: MessageNetwork) -> some View {
    BridgeWebLoginView(network: network) { cookies in
      store.handleWebSessionCookies(cookies, network: network)
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
    )
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Code PIN (X Chat)

  /// Le code à quatre chiffres que X demande après la session. On ne le garde
  /// nulle part : il part au bot, qui le rédige aussitôt.
  private func passcodePanel(_ prompt: (isSetup: Bool, hint: String?)) -> some View {
    VStack(spacing: Spacing.md) {
      Spacer()
      if let hint = prompt.hint {
        Text(hint)
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.ink)
          .multilineTextAlignment(.center)
      }
      TextField(prompt.isSetup ? "Nouveau code PIN" : "Code PIN", text: $passcode)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 26, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: 160)
        .onChange(of: passcode) { _, value in
          passcode = String(value.filter(\.isNumber).prefix(4))
        }
        .onSubmit(sendPasscode)
      Button(prompt.isSetup ? "Créer le code" : "Déverrouiller", action: sendPasscode)
        .keyboardShortcut(.defaultAction)
        .disabled(passcode.count != 4)
      Spacer()
    }
    .padding(Spacing.lg)
  }

  private func sendPasscode() {
    guard passcode.count == 4 else { return }
    store.submitBridgeLoginPasscode(passcode)
    passcode = ""
  }

  // MARK: - Coller la session (le repli)

  /// Quand ni le formulaire ni l'import ne passent : les cookies, copiés depuis
  /// les outils de développement, avec le mode d'emploi du réseau.
  private func manualCookiesPanel(for network: MessageNetwork) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let profile = BridgeSessionCookies.Profile.of(network) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(profile.manualCookieStepsFR.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("\(index + 1).")
                .monospacedDigit()
                .foregroundStyle(theme.inkTertiary)
              Text(LocalizedStringKey(step))
            }
          }
        }
        .font(Typography.body(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .textSelection(.enabled)
        .onAppear { if cookies.isEmpty { cookies = profile.manualCookieTemplate } }
      }

      TextEditor(text: $cookies)
        .font(.system(size: 13, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(Spacing.xs)
        .frame(minHeight: 120)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.sidebar)
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
            )
        )

      HStack {
        Text("Une commande cURL copiée depuis l’onglet Réseau convient aussi.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkTertiary)
        Spacer()
        Button("Envoyer") { store.submitBridgeLoginCookies(cookies) }
          .keyboardShortcut(.defaultAction)
          // Le modèle pré-rempli, avec ses « … », n'est pas encore une session.
          .disabled(cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cookies.contains("…"))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.md)
  }
}
