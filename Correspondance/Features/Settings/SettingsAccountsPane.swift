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
          + "et Signal, tes identifiants pour Instagram, Messenger, X et Slack. "
          + "Signal ne montre que les messages reçus après la liaison. "
          + "Déconnecter un compte ferme sa session côté réseau ; ses conversations restent ici, en historique."
      ) {
        ForEach(Array(MessageNetwork.matrixBridged.enumerated()), id: \.element.id) { index, network in
          if index > 0 { SettingsDivider() }
          SettingsRow(
            label: network.labelFR,
            detail: accountsDetail(for: network),
            systemImage: network.systemImage
          ) {
            HStack(spacing: Spacing.xs) {
              disconnectControl(for: network)
              Button((store.bridgeAccounts[network]?.isEmpty ?? true) ? "Connecter…" : "Ajouter un compte…") {
                store.presentBridgeLogin(network: network)
              }
              .disabled(!store.isMatrixConnected)
            }
          }
        }
      }

      HStack {
        Spacer()
        Button("Actualiser") {
          Task {
            await store.refresh()
            await store.refreshBridgeAccounts()
          }
        }
        .disabled(store.bridgeAccountsBusy)
      }
    }
    // `id:` sur l'état de connexion : le volet s'ouvre souvent avant que le
    // Relais ait répondu, la lecture s'arrêtait à la garde, et « Lecture des
    // comptes… » restait affiché pour toujours. La connexion venue, on relit.
    .task(id: store.isMatrixConnected) { await store.refreshBridgeAccounts() }
  }

  /// La ligne d'état d'un réseau : ses comptes et leur état, ou pourquoi on ne
  /// les connaît pas — et, toujours, ce qu'est un compte sur ce réseau.
  private func accountsDetail(for network: MessageNetwork) -> String {
    guard store.isMatrixConnected else { return "Connecte d’abord le Relais." }
    if let error = store.bridgeAccountsErrors[network] {
      return "Comptes inconnus : \(error)"
    }
    guard let accounts = store.bridgeAccounts[network] else { return "Lecture des comptes…" }
    let hint = network.bridge?.accountsHintFR ?? ""
    if accounts.isEmpty { return "Aucun compte connecté. " + hint }
    let lines = accounts.map { "\($0.labelFR) — \($0.stateFR)" }
    return lines.joined(separator: "\n") + "\n" + hint
  }

  /// « Déconnecter » : un bouton pour un compte, un menu s'il y en a plusieurs.
  @ViewBuilder
  private func disconnectControl(for network: MessageNetwork) -> some View {
    if let accounts = store.bridgeAccounts[network], !accounts.isEmpty {
      if accounts.count == 1, let account = accounts.first {
        Button("Déconnecter") { store.disconnectBridgeAccount(account, network: network) }
          .disabled(store.bridgeAccountsBusy)
          .help("Ferme la session \(network.labelFR) de \(account.labelFR) sur le Relais.")
      } else {
        Menu("Déconnecter…") {
          ForEach(accounts) { account in
            Button(account.labelFR) { store.disconnectBridgeAccount(account, network: network) }
          }
        }
        .disabled(store.bridgeAccountsBusy)
        .fixedSize()
      }
    }
  }
}
