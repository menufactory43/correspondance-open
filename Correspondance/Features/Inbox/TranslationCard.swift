import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Les deux réglages de traduction d'un fil, dans sa fiche : « Traduire ce
/// qui arrive » et « Traduire ce que j'envoie », chacun vers une langue ou
/// « Non ». Sous-titre « Sur cet appareil », parce que c'est la vérité entière :
/// rien ne part au Relais, rien ne part chez Apple, et l'iPhone a ses
/// propres réglages.
///
/// `@AppStorage` sur les clés de `TranslationPreferences` : le sélecteur
/// écrit, les bulles lisent, personne ne relie rien.
struct TranslationCard: View {
  let conversationID: String
  let theme: WritingTheme

  @AppStorage private var incoming: String
  @AppStorage private var outgoing: String

  init(conversationID: String, theme: WritingTheme) {
    self.conversationID = conversationID
    self.theme = theme
    _incoming = AppStorage(wrappedValue: "", TranslationPreferences.incomingKey(conversationID))
    _outgoing = AppStorage(wrappedValue: "", TranslationPreferences.outgoingKey(conversationID))
  }

  var body: some View {
    // Sans le framework `Translation` (macOS 15), rien à régler : on ne
    // montre pas un sélecteur qui ne ferait rien.
    if #available(macOS 15, *) {
      Divider()
      Text("Traduction")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      row("Traduire ce qui arrive", selection: $incoming)
      row("Traduire ce que j'envoie", selection: $outgoing)
    }
  }

  private func row(_ title: String, selection: Binding<String>) -> some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.ink)
        Text("Sur cet appareil")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Picker(title, selection: selection) {
        Text("Non").tag("")
        Divider()
        ForEach(TranslationPreferences.Language.allCases) { language in
          Text(language.titleFR).tag(language.rawValue)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .accessibilityLabel(title)
    }
  }
}
