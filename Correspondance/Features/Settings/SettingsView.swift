import AppKit
import SwiftUI

struct SettingsView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var homeserver = InboxStore.defaultHomeserver
  @State private var matrixUser = "meffysto"
  @State private var matrixPassword = ""
  @State private var isConnectingMatrix = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    Form {
      Section("Comptes") {
        LabeledContent("iMessage") {
          Text(store.iMessageStatusFR)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320, alignment: .trailing)
        }

        LabeledContent("Signal") {
          Text(store.signalStatusFR)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320, alignment: .trailing)
        }

        LabeledContent("Contacts") {
          Text(store.contactsStatusFR)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320, alignment: .trailing)
        }

        LabeledContent("Messages") {
          Text(store.messagesAutomationStatusFR)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320, alignment: .trailing)
        }

        LabeledContent("Notifications") {
          Text(store.notificationStatusFR)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320, alignment: .trailing)
        }

        Text("Lier Signal (terminal) :\nsignal-cli link -n Correspondance\nPuis scanne le QR avec Signal → Appareils liés.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Button("Autoriser Contacts…") {
          Task { await store.requestContactsPermission() }
        }

        Button("Autoriser les notifications…") {
          Task {
            await store.requestNotificationPermission()
            // Déjà refusé : macOS ne réaffiche plus la boîte, on ouvre les Réglages.
            if store.notificationStatusFR.contains("refus") {
              store.openNotificationSettings()
            }
          }
        }

        Button("Autoriser Messages (Automatisation)…") {
          let ok = store.requestMessagesAutomation()
          if !ok { store.openAutomationPrivacySettings() }
        }

        Button("Ouvrir Confidentialité → Accès disque") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }

        Button("Ouvrir Confidentialité → Contacts") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
          }
        }

        Button("Ouvrir Confidentialité → Automatisation") {
          store.openAutomationPrivacySettings()
        }

        Button("Actualiser les comptes") {
          Task { await store.refresh() }
        }
      }

      matrixSection

      Section("Affichage") {
        Picker("Mode au démarrage", selection: Binding(
          get: { store.mode },
          set: { store.setMode($0) }
        )) {
          ForEach(InboxMode.allCases) { mode in
            Text(mode.labelFR).tag(mode)
          }
        }
        Text("Focus = une conversation. Inbox = liste + fil (Beeper). ⌘1 / ⌘2.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Police") {
        Picker("Famille", selection: Binding(
          get: { themes.typeface },
          set: { themes.typeface = $0 }
        )) {
          ForEach(WritingTypeface.allCases) { face in
            Text("\(face.labelFR) — \(face.subtitleFR)").tag(face)
          }
        }

        LabeledContent("Taille") {
          Slider(
            value: Binding(
              get: { themes.typeScale },
              set: { themes.typeScale = $0 }
            ),
            in: 0.9...1.25,
            step: 0.05
          )
          .frame(minWidth: 160)
        }

        Text("Aperçu — Correspondance lit comme iA Writer.")
          .font(Typography.body(themes.typeface, size: 16 * themes.typeScale))
          .foregroundStyle(theme.ink)
          .padding(.vertical, 4)
      }

      Section("Ambiance") {
        ThemePickerView(selection: Binding(
          get: { themes.themeID },
          set: { themes.themeID = $0 }
        ))
        .padding(.vertical, Spacing.xs)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(theme.paper.ignoresSafeArea())
    .sheet(isPresented: Binding(
      get: { store.isPresentingWhatsAppLogin },
      set: { store.isPresentingWhatsAppLogin = $0 }
    )) {
      WhatsAppLoginSheet()
    }
    .task { await store.refreshMatrixStatus() }
  }

  /// Homeserver Matrix (NUC via Tailscale) + connexion WhatsApp par le bot mautrix.
  @ViewBuilder
  private var matrixSection: some View {
    Section("Matrix") {
      LabeledContent("État") {
        Text(store.matrixStatusFR)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 320, alignment: .trailing)
      }

      if store.isMatrixConnected {
        Button("Connecter WhatsApp…") {
          store.presentWhatsAppLogin()
        }
        Text("Ouvre une feuille avec le QR renvoyé par @whatsappbot. Repli si le QR est refusé :\nenvoie « login phone +33… » au bot depuis Element (code d’appairage).")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Button("Déconnecter Matrix") {
          Task { await store.disconnectMatrix() }
        }
      } else {
        TextField("Homeserver", text: $homeserver)
          .textFieldStyle(.roundedBorder)
        TextField("Identifiant", text: $matrixUser)
          .textFieldStyle(.roundedBorder)
        SecureField("Mot de passe", text: $matrixPassword)
          .textFieldStyle(.roundedBorder)
        Button(isConnectingMatrix ? "Connexion…" : "Connexion") {
          isConnectingMatrix = true
          Task {
            await store.connectMatrix(
              homeserver: homeserver,
              user: matrixUser,
              password: matrixPassword
            )
            matrixPassword = ""
            isConnectingMatrix = false
          }
        }
        .disabled(isConnectingMatrix || matrixUser.isEmpty || matrixPassword.isEmpty)
      }
    }
  }
}
