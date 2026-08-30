import SwiftUI

/// Feuille « Connecter <réseau> » : ce que le pont demande, et rien d'autre.
/// WhatsApp fait scanner un QR ; Instagram fait coller les cookies d'une session
/// de navigateur déjà connectée — Meta n'expose pas d'autre porte d'entrée.
struct BridgeLoginSheet: View {
  let network: MessageNetwork

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var cookies = ""

  private var theme: WritingTheme { themes.theme }
  private var flow: MatrixBridgeDescriptor.LoginFlow { network.bridge?.loginFlow ?? .qrCode }

  var body: some View {
    VStack(spacing: Spacing.md) {
      Text("Connecter \(network.labelFR)")
        .font(Typography.sidebarItem(themes.typeface))
        .foregroundStyle(theme.ink)

      switch flow {
      case .qrCode: qrCodePanel
      case .cookies: cookiesPanel
      }

      Text(store.bridgeLoginStatusFR)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)

      HStack {
        Button("Relancer") { store.presentBridgeLogin(network: network) }
        Spacer()
        if flow == .cookies {
          Button("Envoyer") { store.submitBridgeLoginCookies(cookies) }
            .keyboardShortcut(.defaultAction)
            .disabled(cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Button("Fermer") {
          store.stopBridgeLoginPolling()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(Spacing.lg)
    .frame(minWidth: flow == .cookies ? 460 : 380)
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

  // MARK: - Cookies (Instagram)

  @ViewBuilder
  private var cookiesPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Colle ici tes cookies \(network.labelFR)")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.ink)

      TextEditor(text: $cookies)
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(Spacing.xs)
        .frame(height: 160)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.sidebar)
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
            )
        )

      Text("""
        Dans un navigateur connecté à instagram.com : Outils de développement → Application \
        (Storage) → Cookies → https://www.instagram.com. Le bot attend un objet JSON avec \
        sessionid, csrftoken, ds_user_id, mid et ig_did — une commande cURL copiée depuis \
        l'onglet Réseau fait aussi l'affaire.
        """)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: 400)
  }
}
