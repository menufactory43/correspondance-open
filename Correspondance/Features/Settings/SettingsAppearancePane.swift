import SwiftUI

/// Mode d'ouverture, police, ambiance — tout ce qui change la façon dont
/// Correspondance se lit, avec l'aperçu juste sous le réglage qui l'affecte.
struct SettingsAppearancePane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  /// Éteint par défaut : une notification ouvre l'inbox, comme toujours.
  @AppStorage(DetachedWindowState.notificationsOpenDetachedKey)
  private var notificationsOpenDetached = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Ouverture",
        footnote: "Focus = une conversation. Inbox = liste + fil. ⌘1 / ⌘2. "
          + "Une conversation se détache dans sa fenêtre avec ⌘⇧D."
      ) {
        SettingsRow(label: "Mode au démarrage", systemImage: "rectangle.split.2x1") {
          Picker("", selection: Binding(
            get: { store.mode },
            set: { store.setMode($0) }
          )) {
            ForEach(InboxMode.allCases) { mode in
              Text(mode.labelFR).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 200)
        }

        SettingsDivider()

        SettingsRow(label: "Ouvrir les notifications en fenêtre détachée", systemImage: "macwindow.on.rectangle") {
          Toggle("", isOn: $notificationsOpenDetached)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      SettingsCard(title: "Police") {
        SettingsRow(label: "Famille", systemImage: "textformat") {
          Picker("", selection: Binding(
            get: { themes.typeface },
            set: { themes.typeface = $0 }
          )) {
            ForEach(WritingTypeface.allCases) { face in
              Text("\(face.labelFR) — \(face.subtitleFR)").tag(face)
            }
          }
          .frame(width: 260)
        }

        SettingsDivider()

        SettingsRow(label: "Taille", systemImage: "textformat.size") {
          Slider(
            value: Binding(
              get: { themes.typeScale },
              set: { themes.typeScale = $0 }
            ),
            in: 0.9...1.25,
            step: 0.05
          )
          .frame(width: 200)
        }

        SettingsDivider()

        Text("Aperçu — Correspondance lit comme iA Writer.")
          .font(Typography.body(themes.typeface, size: 16 * themes.typeScale))
          .foregroundStyle(theme.ink)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm)
      }

      SettingsCard(
        title: "Fil",
        footnote: "En Inbox. La page Focus se lit comme une lettre — elle n'a pas de visages."
      ) {
        SettingsRow(label: "Photo de l'expéditeur", systemImage: "person.crop.circle") {
          Toggle("", isOn: Binding(
            get: { themes.showsMessageAvatars },
            set: { themes.showsMessageAvatars = $0 }
          ))
          .toggleStyle(.switch)
        }
      }

      SettingsCard(
        title: "Arrivée d'un message",
        footnote: "En Focus. L'Inbox garde l'encre — la plume est faite pour la prose."
      ) {
        SettingsRow(label: "Geste", systemImage: "wand.and.sparkles") {
          Picker("", selection: Binding(
            get: { themes.messageArrival },
            set: { themes.messageArrival = $0 }
          )) {
            ForEach(MessageArrival.allCases) { arrival in
              Text("\(arrival.labelFR) — \(arrival.subtitleFR)").tag(arrival)
            }
          }
          .frame(width: 260)
        }
      }

      SettingsCard(title: "Ambiance") {
        ThemePickerView(selection: Binding(
          get: { themes.themeID },
          set: { themes.themeID = $0 }
        ))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
      }
    }
  }
}
