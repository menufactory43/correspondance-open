import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

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
          iMessage se lit dans la base de Messages, et s’envoie en pilotant l’app —
          rien à connecter.
          """
      ) {
        SettingsRow(
          label: MessageNetwork.iMessage.labelFR,
          detail: store.iMessageStatusFR,
          systemImage: MessageNetwork.iMessage.systemImage
        )
      }

      SettingsCard(
        title: "Réseaux pontés (Matrix)",
        footnote: """
          WhatsApp : @whatsappbot renvoie un QR ; s’il est refusé, « login phone +33… » \
          donne un code d’appairage.
          Instagram : @instagrambot demande les cookies d’une session instagram.com — \
          la feuille explique où les prendre.
          Messenger : @messengerbot fait pareil, sur facebook.com — la connexion se fait \
          par e-mail et mot de passe dans la fenêtre, 2FA comprise.
          Signal : @signalbot renvoie un QR à scanner depuis Réglages → Appareils liés. \
          Le pont ne verra que les messages postérieurs à la liaison.
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
