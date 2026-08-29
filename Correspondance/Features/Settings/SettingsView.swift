import AppKit
import SwiftUI

struct SettingsView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

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

        Text("Lier Signal (terminal) :\nsignal-cli link -n Correspondance\nPuis scanne le QR avec Signal → Appareils liés.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Button("Autoriser Contacts…") {
          Task { await store.requestContactsPermission() }
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
  }
}
