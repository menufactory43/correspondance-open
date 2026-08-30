import SwiftUI

/// Mode d'ouverture, police, ambiance — tout ce qui change la façon dont
/// Correspondance se lit, avec l'aperçu juste sous le réglage qui l'affecte.
struct SettingsAppearancePane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Ouverture",
        footnote: "Focus = une conversation. Inbox = liste + fil. ⌘1 / ⌘2."
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
