import SwiftUI

/// Feuille « Connecter <réseau> » : ce que le pont demande, et rien d'autre.
/// WhatsApp fait scanner un QR ; Instagram ouvre une vraie fenêtre de connexion
/// instagram.com dans l'app — Meta ne connaît que la session d'un navigateur, mais
/// l'utilisateur n'a rien à savoir des cookies pour autant.
struct BridgeLoginSheet: View {
  let network: MessageNetwork

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var cookies = ""
  /// Repli pour le jour où Meta bloquera la fenêtre intégrée : replié par défaut,
  /// parce que personne ne devrait avoir à ouvrir les outils de développement.
  @State private var showsManualCookies = false

  private var theme: WritingTheme { themes.theme }
  private var flow: MatrixBridgeDescriptor.LoginFlow { network.bridge?.loginFlow ?? .qrCode }

  var body: some View {
    VStack(spacing: Spacing.md) {
      Text("Connecter \(network.labelFR)")
        .font(Typography.sidebarItem(themes.typeface))
        .foregroundStyle(theme.ink)

      switch flow {
      case .qrCode: qrCodePanel
      case .webSession: webSessionPanel
      }

      Text(store.bridgeLoginStatusFR)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)

      HStack {
        Button("Relancer") { store.presentBridgeLogin(network: network) }
        Spacer()
        Button("Fermer") {
          store.stopBridgeLoginPolling()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(Spacing.lg)
    .frame(minWidth: flow == .webSession ? 460 : 380)
    .background(theme.paper)
    .onDisappear { store.stopBridgeLoginPolling() }
  }

  // MARK: - QR (WhatsApp)

  @ViewBuilder
  private var qrCodePanel: some View {
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
    .frame(width: 260, height: 260)

    if let code = store.bridgeLoginPairingCode {
      Text(code)
        .font(.system(size: 26, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.ink)
        .textSelection(.enabled)
    }
  }

  // MARK: - Fenêtre de connexion (Instagram)

  @ViewBuilder
  private var webSessionPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      InstagramWebLoginView { cookies in
        store.handleInstagramSessionCookies(cookies)
      }
      // La feuille vit dans la fenêtre Réglages (660 pt de haut au mieux) : le formulaire
      // Instagram tient dans 360 pt, et la page défile à l'intérieur pour le reste.
      .frame(width: 420, height: 360)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
      )

      DisclosureGroup("Coller des cookies…", isExpanded: $showsManualCookies) {
        manualCookiesPanel
      }
      .font(Typography.meta(themes.typeface))
      .foregroundStyle(theme.inkSecondary)
    }
  }

  /// L'ancienne saisie, gardée en secours : si la fenêtre reste blanche ou qu'Instagram
  /// refuse le navigateur intégré, on peut encore coller la session à la main.
  @ViewBuilder
  private var manualCookiesPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      TextEditor(text: $cookies)
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(Spacing.xs)
        .frame(height: 90)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.sidebar)
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
            )
        )

      HStack {
        Text("Un objet JSON, ou un « Copy as cURL » de l'onglet Réseau.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
        Spacer()
        Button("Envoyer") { store.submitBridgeLoginCookies(cookies) }
          .disabled(cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(.top, Spacing.xs)
  }
}
