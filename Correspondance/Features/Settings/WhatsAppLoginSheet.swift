import SwiftUI

/// Feuille « Connecter WhatsApp » : QR renvoyé par `@whatsappbot`, ou code d'appairage.
struct WhatsAppLoginSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(spacing: Spacing.md) {
      Text("Connecter WhatsApp")
        .font(Typography.sidebarItem(themes.typeface))
        .foregroundStyle(theme.ink)

      qrPanel

      if let code = store.whatsAppLoginPairingCode {
        Text(code)
          .font(.system(size: 26, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.ink)
          .textSelection(.enabled)
      }

      Text(store.whatsAppLoginStatusFR)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)

      HStack {
        Button("Relancer") { store.presentWhatsAppLogin() }
        Spacer()
        Button("Fermer") {
          store.stopWhatsAppLoginPolling()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(Spacing.lg)
    .frame(minWidth: 380)
    .background(theme.paper)
    .onDisappear { store.stopWhatsAppLoginPolling() }
  }

  @ViewBuilder
  private var qrPanel: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
        )
      if let data = store.whatsAppLoginQRData, let image = NSImage(data: data) {
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
  }
}
