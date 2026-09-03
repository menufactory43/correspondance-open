// Sans le framework `Translation` (macOS 15), le panneau n'existe pas : l'envoi
// part comme avant.
#if canImport(Translation)
import SwiftUI
@preconcurrency import Translation
import CorrespondanceCore
import CorrespondanceUI

/// « Traduire ce que j'envoie » : le brouillon traduit, montré au-dessus de la
/// saisie avant de partir, avec le choix — la traduction ou l'original.
///
/// Rien ne part tant qu'on n'a pas choisi : Entrée a ouvert ce panneau au lieu
/// d'envoyer, et c'est l'un des deux boutons qui envoie. La traduction se fait
/// ici, sur la machine, par la session `Translation` que porte cette vue.
/// Ce que l'envoi a retenu : le fil, le texte tel qu'il était, la langue.
/// Hors du panneau, parce qu'un `@State` de `ThreadView` le porte, et que
/// `ThreadView` vit aussi sur macOS 14.
struct OutgoingTranslationRequest: Equatable {
  let conversationID: String
  let draft: String
  let target: String
}

@available(macOS 15, *)
struct OutgoingTranslationPanel: View {
  typealias Request = OutgoingTranslationRequest

  let request: Request
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  /// Le panneau se ferme — envoyé ou non.
  let onDone: () -> Void

  @Environment(InboxStore.self) private var store
  @State private var translated: String?
  @State private var failure: String?
  @State private var configuration: TranslationSession.Configuration?

  private var languageFR: String { TranslationPreferences.enFR(request.target) }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: 6) {
        Image(systemName: "character.bubble")
          .font(.system(size: 11, weight: .medium))
        Text("Traduit \(languageFR) · sur cet appareil")
          .font(Typography.meta(typeface))
        Spacer(minLength: 0)
        Button {
          onDone()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Revenir au brouillon")
        .accessibilityLabel("Fermer sans envoyer")
      }
      .foregroundStyle(theme.inkSecondary)

      if let translated {
        Text(translated)
          .font(Typography.bubble(typeface))
          .foregroundStyle(theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let failure {
        Text(failure)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Traduction…")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }

      HStack(spacing: Spacing.xs) {
        Button("Envoyer \(languageFR)") { send(translated) }
          .keyboardShortcut(.defaultAction)
          .disabled(translated == nil)
        Button("Envoyer l’original") { send(nil) }
      }
      .controlSize(.small)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.paperSecondary)
    .overlay(alignment: .top) { Divider() }
    .task(id: request) {
      translated = nil
      failure = nil
      configuration = TranslationSession.Configuration(
        source: TextTranslator.language(of: request.draft).map { Locale.Language(identifier: $0) },
        target: Locale.Language(identifier: request.target)
      )
    }
    .translationTask(configuration) { session in
      do {
        let result = try await session.translate(request.draft).targetText
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw TextTranslator.Failure.unavailable }
        translated = result
      } catch {
        failure = "Traduction indisponible \(languageFR) sur cet appareil. L’original peut partir tel quel."
      }
    }
  }

  /// Envoyer — la traduction remplace le brouillon, l'original part tel quel.
  private func send(_ text: String?) {
    if let text { store.draftText = text }
    onDone()
    Task { await store.sendDraft() }
  }
}

@available(macOS 15, *)
extension OutgoingTranslationPanel {
  /// L'envoi, vu du composer : ouvrir le panneau si le fil traduit ce qui
  /// part, envoyer sinon. C'est la seule ligne que `ThreadView` a à connaître.
  ///
  /// Un brouillon déjà dans la langue cible part sans passer par le panneau ;
  /// un brouillon vide (pièces jointes seules) aussi.
  @MainActor
  static func send(store: InboxStore, request: Binding<Request?>) {
    let draft = store.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = store.selectedConversationID,
       store.editingMessage == nil,
       let target = TranslationPreferences.shared.outgoingTarget(for: id),
       !draft.isEmpty,
       TextTranslator.language(of: draft).map({ !TextTranslator.sameLanguage($0, target) }) ?? true {
      request.wrappedValue = Request(conversationID: id, draft: draft, target: target)
      return
    }
    Task { await store.sendDraft() }
  }
}
#endif
