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
        title: "Sur ce Mac",
        footnote: "iMessage marche tout seul : Correspondance lit Messages et envoie par lui. Rien à connecter."
      ) {
        SettingsRow(
          label: MessageNetwork.iMessage.labelFR,
          detail: store.iMessageStatusFR,
          systemImage: MessageNetwork.iMessage.systemImage
        )
      }

      SettingsCard(
        title: "Par le Relais",
        footnote: "Chaque réseau se connecte comme sur un nouveau téléphone : un QR code pour WhatsApp "
          + "et Signal, tes identifiants pour Instagram, Messenger et X. "
          + "Signal ne montre que les messages reçus après la liaison."
      ) {
        ForEach(Array(MessageNetwork.matrixBridged.enumerated()), id: \.element.id) { index, network in
          if index > 0 { SettingsDivider() }
          SettingsRow(
            label: network.labelFR,
            detail: store.isMatrixConnected
              ? "Prêt à connecter."
              : "Connecte d’abord le Relais.",
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
        Button("Actualiser") {
          Task { await store.refresh() }
        }
      }
    }
  }
}
