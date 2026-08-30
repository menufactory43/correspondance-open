import SwiftUI

/// Le homeserver Matrix (Synapse sur le NUC, via Tailscale) : l'état du lien,
/// et le formulaire de session quand il n'y en a pas.
struct SettingsMatrixPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var homeserver = InboxStore.defaultHomeserver
  @State private var matrixUser = "meffysto"
  @State private var matrixPassword = ""
  @State private var isConnecting = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(title: "État") {
        SettingsRow(
          label: "Homeserver",
          detail: store.matrixStatusFR,
          systemImage: store.isMatrixConnected ? "checkmark.seal.fill" : "exclamationmark.triangle"
        ) {
          Button("Re-sonder") {
            Task { await store.refreshMatrixStatus() }
          }
        }
      }

      if store.isMatrixConnected {
        SettingsCard(title: "Session") {
          SettingsRow(
            label: "Fermer la session",
            detail: "Les conversations WhatsApp et Instagram quittent l’inbox jusqu’à la prochaine connexion."
          ) {
            Button("Déconnecter") {
              Task { await store.disconnectMatrix() }
            }
          }
        }
      } else {
        SettingsCard(title: "Connexion") {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Homeserver", text: $homeserver)
            TextField("Identifiant", text: $matrixUser)
            SecureField("Mot de passe", text: $matrixPassword)
          }
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)

          HStack {
            Spacer()
            Button(isConnecting ? "Connexion…" : "Connexion") {
              connect()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isConnecting || matrixUser.isEmpty || matrixPassword.isEmpty)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
        }
      }
    }
  }

  private func connect() {
    isConnecting = true
    Task {
      await store.connectMatrix(
        homeserver: homeserver,
        user: matrixUser,
        password: matrixPassword
      )
      matrixPassword = ""
      isConnecting = false
    }
  }
}
