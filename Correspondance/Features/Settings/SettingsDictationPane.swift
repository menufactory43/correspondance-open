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
          ? "Transcription 100 % locale (Parakeet / Whisper). Le micro du composer démarre et arrête "
            + "Dictus, qui colle le texte dans le champ. Le raccourci de Dictus reste utilisable"
            + (DictusBridge.transcribeShortcutFR.map { " (\($0))" } ?? "") + "."
          : "Dictus n’est pas installé : la dictée passe par la reconnaissance vocale d’Apple."
      ) {
        SettingsRow(
          label: "Dicter avec Dictus",
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
          label: "Dictus est un logiciel libre (MIT)",
          detail: "Merci à ses auteurs — getdictus.com",
          systemImage: "heart"
        ) {
          Button(isInstalled ? "Site" : "Télécharger") { DictusBridge.openWebsite() }
        }
      }

      SettingsCard(
        title: "Sans Dictus",
        footnote: "Reconnaissance vocale d’Apple, sur l’appareil quand la langue le permet ; "
          + "à défaut, la dictée système de macOS."
      ) {
        SettingsRow(label: "Micro et reconnaissance vocale", systemImage: "mic") {
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
    if !isInstalled { return "Non installé" }
    if !useDictus { return "Installé, non utilisé" }
    return isRunning ? "Actif" : "Installé — lancé au premier appui sur le micro"
  }

  private func openPrivacy(_ anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
    Platform.open(url)
  }
}
