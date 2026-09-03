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
  @State private var inputText = ""
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
          } else if network.bridge?.provisionedLoginFlowID != nil {
            // Slack : l'API de provisioning décrit chaque étape — une saisie
            // (e-mail, code, espace de travail), ou une page à ouvrir avec le
            // script qui en tire la réponse (le captcha). Comme Beeper.
            provisionedStepPanel
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
      if network == .slack {
        "Connecte-toi par e-mail : tu recevras un code, puis tu choisiras ton espace de travail."
      } else if network == .twitter {
        "Connecte-toi comme sur x.com. Si ton compte a une passkey, passe par ton navigateur, en bas."
      } else {
        "Connecte-toi comme sur le site : identifiants, code à deux facteurs, tout se passe ici."
      }
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
          if let url = loginURL(for: network) {
            Button("Ouvrir dans le navigateur") { NSWorkspace.shared.open(url) }
              .help("Ouvre la page de connexion dans ton navigateur habituel. Reviens ensuite ici pour importer ou coller la session.")
          }
          Toggle(isOn: $showsManualCookies) { Text("Coller la session") }
            .toggleStyle(.button)
            .onChange(of: showsManualCookies) { _, on in
              // Slack : le flow token et le flow e-mail s'excluent — passer au
              // collage démarre le flow `token` ; revenir relance l'e-mail.
              guard network == .slack else { return }
              if on { store.beginSlackTokenLogin() } else { store.presentBridgeLogin(network: network) }
            }
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

  // MARK: - Selon le réseau

  /// La page de connexion à ouvrir dans le navigateur, s'il y en a une.
  private func loginURL(for network: MessageNetwork) -> URL? {
    if let profile = BridgeSessionCookies.Profile.of(network) { return profile.loginURL }
    return network == .slack ? SlackLoginSession.loginURL : nil
  }

  /// Le mode d'emploi du repli, du profil de cookies ou — pour Slack — de sa propre session.
  private func manualSteps(for network: MessageNetwork) -> [String] {
    if let profile = BridgeSessionCookies.Profile.of(network) { return profile.manualCookieStepsFR }
    return network == .slack ? SlackLoginSession.manualStepsFR : []
  }

  private func manualTemplate(for network: MessageNetwork) -> String {
    if let profile = BridgeSessionCookies.Profile.of(network) { return profile.manualCookieTemplate }
    return network == .slack ? SlackLoginSession.manualTemplate : ""
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

  // MARK: - Les étapes de l'API de provisioning (Slack)

  /// L'étape en cours, selon son type : une saisie, ou une page à ouvrir dont le
  /// script rend la réponse. Le captcha de Slack est de la seconde sorte.
  @ViewBuilder
  private var provisionedStepPanel: some View {
    if let step = store.bridgeLoginProcessStep, step.type == .cookies, let params = step.cookies {
      BridgeExtractionWebView(
        params: params,
        onValues: { values in store.submitBridgeLoginExtractedValues(values) },
        onError: { message in store.bridgeLoginStatusFR = message },
        scriptTransform: { SlackLoginFrench.localizedExtractJS($0) }
      )
      .id(step.stepID + step.loginID)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
      )
      .padding(.horizontal, Spacing.lg)
      .padding(.bottom, Spacing.md)
    } else {
      slackInputPanel
    }
  }

  /// La question du pont et un champ pour y répondre : e-mail, code reçu par mail,
  /// choix de l'espace de travail. L'instruction du pont est la question elle-même.
  @ViewBuilder
  private var slackInputPanel: some View {
    if let prompt = store.bridgeLoginInputPrompt {
      VStack(spacing: Spacing.md) {
        Spacer()
        Text(LocalizedStringKey(cleanedPrompt(prompt.prompt)))
          .font(Typography.body(themes.typeface))
          .foregroundStyle(theme.ink)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
          .textSelection(.enabled)
        if prompt.options.isEmpty {
          field(secret: prompt.isSecret)
        } else {
          // Le choix de l'espace de travail : un bouton par option.
          VStack(spacing: Spacing.xs) {
            ForEach(prompt.options, id: \.self) { option in
              Button(option) { store.submitBridgeLoginInput(option) }
                .buttonStyle(.borderedProminent)
            }
          }
          field(secret: false)
        }
        Spacer()
      }
      .padding(Spacing.lg)
    } else {
      VStack(spacing: Spacing.md) {
        ProgressView()
        Text("Préparation de la connexion Slack…")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func field(secret: Bool) -> some View {
    HStack {
      Group {
        if secret {
          SecureField("Ta réponse", text: $inputText)
        } else {
          TextField("Ta réponse", text: $inputText)
        }
      }
      .textFieldStyle(.roundedBorder)
      .frame(width: 260)
      .onSubmit(sendInput)
      Button("Envoyer", action: sendInput)
        .keyboardShortcut(.defaultAction)
        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func sendInput() {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    store.submitBridgeLoginInput(text)
    inputText = ""
  }

  /// bridgev2 préfixe souvent la question de l'instruction du connecteur : on garde
  /// la dernière ligne utile, « Please enter your … » compris.
  private func cleanedPrompt(_ body: String) -> String {
    body.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let steps = manualSteps(for: network)
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      if !steps.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
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
        .onAppear { if cookies.isEmpty { cookies = manualTemplate(for: network) } }
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
