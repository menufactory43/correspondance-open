import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Quel moteur écoute quand on appuie sur le micro du composer.
/// Dictus (getdictus.com, MIT) prend la main s'il est installé ; sinon Speech d'Apple.
struct SettingsDictationPane: View {
  @Environment(ThemePreferences.self) private var themes
  @State private var useDictus = DictusBridge.isPreferred
  @State private var isInstalled = DictusBridge.isInstalled
  @State private var isRunning = DictusBridge.isRunning

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Dictus",
        footnote: isInstalled
          ? String(localized: "Tout se passe sur ce Mac, rien ne part sur internet. Le micro lance Dictus, ")
            + String(localized: "qui écrit le texte dans le champ.")
            + (DictusBridge.transcribeShortcutFR.map { String(localized: " Son raccourci (\($0)) marche aussi.") } ?? "")
          : String(localized: "Dictus n’est pas installé. La dictée passe par celle d’Apple.")
      ) {
        SettingsRow(
          label: String(localized: "Dicter avec Dictus"),
          detail: statusFR,
          systemImage: "waveform.badge.mic"
        ) {
          Toggle("", isOn: $useDictus)
            .toggleStyle(.switch)
            .disabled(!isInstalled)
            .onChange(of: useDictus) { _, value in DictusBridge.isPreferred = value }
        }

        SettingsDivider()

        SettingsRow(
          label: String(localized: "Dictus est un logiciel libre"),
          detail: String(localized: "Merci à ses auteurs. getdictus.com"),
          systemImage: "heart"
        ) {
          Button(isInstalled ? String(localized: "Site") : String(localized: "Télécharger")) { DictusBridge.openWebsite() }
        }
      }

      SettingsCard(
        title: String(localized: "Sans Dictus"),
        footnote: String(localized: "La dictée d’Apple, directement sur le Mac quand la langue le permet.")
      ) {
        SettingsRow(label: String(localized: "Micro et reconnaissance vocale"), systemImage: "mic") {
          Button("Autorisations…") { openPrivacy("Privacy_Microphone") }
        }
      }
    }
    .onAppear {
      isInstalled = DictusBridge.isInstalled
      isRunning = DictusBridge.isRunning
    }
  }

  private var statusFR: String {
    if !isInstalled { return String(localized: "Non installé") }
    if !useDictus { return String(localized: "Installé, non utilisé") }
    return isRunning
      ? String(localized: "Actif")
      : String(localized: "Installé, se lance au premier appui sur le micro")
  }

  private func openPrivacy(_ anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
    Platform.open(url)
  }
}
