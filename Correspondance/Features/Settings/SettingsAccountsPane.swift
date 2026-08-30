import SwiftUI

/// Les réseaux, un par ligne, avec leur état et leur seule action utile.
/// La liste se déduit de `MessageNetwork` : un réseau nouveau apparaît ici seul.
struct SettingsAccountsPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Transports natifs",
        footnote: """
          Lier Signal se fait au terminal :
          signal-cli link -n Correspondance
          Puis scanne le QR dans Signal → Appareils liés.
          """
      ) {
        SettingsRow(
          label: MessageNetwork.iMessage.labelFR,
          detail: store.iMessageStatusFR,
          systemImage: MessageNetwork.iMessage.systemImage
        )
        SettingsDivider()
        SettingsRow(
          label: MessageNetwork.signal.labelFR,
          detail: store.signalStatusFR,
          systemImage: MessageNetwork.signal.systemImage
        )
      }

      SettingsCard(
        title: "Réseaux pontés (Matrix)",
        footnote: """
          WhatsApp : @whatsappbot renvoie un QR ; s’il est refusé, « login phone +33… » \
          donne un code d’appairage.
          Instagram : @instagrambot demande les cookies d’une session instagram.com — \
          la feuille explique où les prendre.
          """
      ) {
        ForEach(Array(MessageNetwork.matrixBridged.enumerated()), id: \.element.id) { index, network in
          if index > 0 { SettingsDivider() }
          SettingsRow(
            label: network.labelFR,
            detail: store.isMatrixConnected
              ? "Connexion par le bot mautrix du pont."
              : "Connecte d’abord le serveur Matrix.",
            systemImage: network.systemImage
          ) {
            Button("Connecter…") {
              store.presentBridgeLogin(network: network)
            }
            .disabled(!store.isMatrixConnected)
          }
        }
      }

      HStack {
        Spacer()
        Button("Actualiser les comptes") {
          Task { await store.refresh() }
        }
      }
    }
  }
}
