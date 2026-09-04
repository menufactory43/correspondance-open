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
      // La langue choisie est celle dans laquelle on **lit** ou on **envoie**,
      // pas celle qu'on attend : « Anglais » sur ce qui arrive laissait les
      // bulles anglaises telles quelles, et on cherchait pourquoi.
      row("Ce qui arrive", detail: "Lu, sur cet appareil, en", none: "Sans traduction", selection: $incoming)
      row("Ce que j'envoie", detail: "Traduit avant l'envoi en", none: "Sans traduction", selection: $outgoing)
    }
  }

  private func row(_ title: String, detail: String, none: String, selection: Binding<String>) -> some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.ink)
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Picker(title, selection: selection) {
        Text(none).tag("")
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
