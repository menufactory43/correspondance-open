import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Mode d'ouverture, police, ambiance — tout ce qui change la façon dont
/// Correspondance se lit, avec l'aperçu juste sous le réglage qui l'affecte.
struct SettingsAppearancePane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  /// Éteint par défaut : une notification ouvre l'inbox, comme toujours.
  @AppStorage(DetachedWindowState.notificationsOpenDetachedKey)
  private var notificationsOpenDetached = false

  // Lot F3 — la réponse rapide. Valeurs d'usine : le raccourci répond, le
  // panneau se referme après l'envoi, rien ne s'installe dans la barre des menus.
  @AppStorage(QuickReplyPreferences.enabledKey) private var quickReplyEnabled = true
  @AppStorage(QuickReplyPreferences.hotKeyKey) private var quickReplyHotKey = QuickReplyHotKey.controlOptionSpace
  @AppStorage(QuickReplyPreferences.closeAfterSendKey) private var quickReplyClosesAfterSend = true
  @AppStorage(QuickReplyPreferences.menuBarExtraKey) private var quickReplyMenuBarExtra = false
  @AppStorage(QuickReplyPreferences.avoidFullScreenKey) private var quickReplyAvoidsFullScreen = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Ouverture",
        footnote: "Focus montre une conversation à la fois, Inbox toute la liste. "
          + "⌘1 et ⌘2 pour passer de l’un à l’autre, ⌘⇧D pour détacher une conversation."
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

      SettingsCard(
        title: "Réponse rapide",
        footnote: "Un petit panneau pour répondre sans ouvrir l’app. "
          + "⌘↑ et ⌘↓ changent de conversation, ⌘K en cherche une, Échap ferme."
      ) {
        SettingsRow(label: "Raccourci global", systemImage: "bolt") {
          Toggle("", isOn: $quickReplyEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: quickReplyEnabled) { _, _ in
              QuickReplyPanelController.shared.refreshHotKey()
            }
        }

        SettingsDivider()

        SettingsRow(label: "Combinaison", systemImage: "command") {
          Picker("", selection: $quickReplyHotKey) {
            ForEach(QuickReplyHotKey.allCases) { combo in
              Text(combo.labelFR).tag(combo)
            }
          }
          .labelsHidden()
          .frame(width: 160)
          .disabled(!quickReplyEnabled)
          .onChange(of: quickReplyHotKey) { _, _ in
            QuickReplyPanelController.shared.refreshHotKey()
          }
        }

        SettingsDivider()

        SettingsRow(label: "Fermer après envoi", systemImage: "paperplane") {
          Toggle("", isOn: $quickReplyClosesAfterSend)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsDivider()

        SettingsRow(label: "Icône dans la barre des menus", systemImage: "menubar.arrow.up.rectangle") {
          Toggle("", isOn: $quickReplyMenuBarExtra)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsDivider()

        SettingsRow(label: "Jamais au-dessus d’une app plein écran", systemImage: "arrow.up.left.and.arrow.down.right") {
          Toggle("", isOn: $quickReplyAvoidsFullScreen)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      SettingsCard(
        title: "Police",
        footnote: "⌘+ et ⌘− changent la taille, ⌘0 revient à la normale."
      ) {
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

        SettingsRow(label: "Longueur de ligne", systemImage: "arrow.left.and.right.text.vertical") {
          Picker("", selection: Binding(
            get: { themes.lineLength },
            set: { themes.lineLength = $0 }
          )) {
            ForEach(LineLengthPreset.allCases) { preset in
              Text(preset.labelFR).tag(preset)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 220)
          .help("La colonne de la page Focus, en caractères — elle suit la police et la taille du texte.")
        }

        SettingsDivider()

        SettingsRow(label: "Taille du texte", systemImage: "textformat.size") {
          HStack(spacing: Spacing.xs) {
            Slider(
              value: Binding(
                get: { themes.typeScale },
                set: { themes.typeScale = $0 }
              ),
              in: ThemePreferences.typeScaleRange,
              step: ThemePreferences.typeScaleStep
            )
            .frame(width: 160)

            Text(themes.typeScaleLabelFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              .monospacedDigit()
              .frame(width: 44, alignment: .trailing)

            Button("100 %") { themes.resetTypeScale() }
              .disabled(themes.isTypeScaleDefault)
              .accessibilityLabel("Revenir à la taille normale")
          }
        }

        SettingsDivider()

        Text("Un aperçu de la police, à la taille choisie.")
          .font(Typography.body(themes.typeface, size: Typography.Size.body * themes.textScale))
          .lineSpacing(theme.lineSpacing(forBodySize: Typography.Size.body * themes.textScale))
          .foregroundStyle(theme.ink)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm)
      }

      SettingsCard(
        title: "Fil",
        footnote: "En mode Inbox seulement. Focus reste sans photos, comme une lettre."
      ) {
        SettingsRow(label: "Photo de l'expéditeur", systemImage: "person.crop.circle") {
          Toggle("", isOn: Binding(
            get: { themes.showsMessageAvatars },
            set: { themes.showsMessageAvatars = $0 }
          ))
          .toggleStyle(.switch)
        }

        SettingsDivider()

        SettingsRow(label: "Aperçu des liens", systemImage: "link") {
          Toggle("", isOn: Binding(
            get: { themes.showsLinkPreviews },
            set: { themes.showsLinkPreviews = $0 }
          ))
          .toggleStyle(.switch)
        }
      }

      SettingsCard(
        title: "Arrivée d'un message",
        footnote: "En mode Focus seulement."
      ) {
        SettingsRow(label: "Animation", systemImage: "wand.and.sparkles") {
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
