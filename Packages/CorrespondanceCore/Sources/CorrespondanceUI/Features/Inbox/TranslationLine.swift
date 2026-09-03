// Sans le framework `Translation` (macOS 15 / iOS 18), la ligne n'existe pas.
#if canImport(Translation)
import SwiftUI
@preconcurrency import Translation
import CorrespondanceCore

/// La traduction d'une bulle, en gris dessous — « Traduit · sur cet appareil ».
///
/// C'est ici que vit la session `Translation` : elle ne s'obtient que par le
/// modificateur `.translationTask`, posé sur une vue. La ligne demande d'abord
/// au cache de `TextTranslator`, et ne monte une session que s'il ne sait pas.
/// Le système télécharge les modèles de langue à la première demande (une
/// feuille à lui), puis tout tourne sur la machine.
@available(macOS 15, iOS 18, *)
public struct TranslationLine: View {
  public let messageID: String
  public let text: String
  /// La langue reconnue du texte ; `nil` laisse la session deviner.
  public let source: String?
  public let target: String
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var font: Font

  @State private var translated: String?
  @State private var failure: String?
  @State private var configuration: TranslationSession.Configuration?

  public init(
    messageID: String,
    text: String,
    source: String?,
    target: String,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    font: Font
  ) {
    self.messageID = messageID
    self.text = text
    self.source = source
    self.target = target
    self.theme = theme
    self.typeface = typeface
    self.font = font
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if let translated {
        Text(translated)
          .font(font)
          .foregroundStyle(theme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      } else if let failure {
        Text(failure)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Traduction…")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }
      if failure == nil {
        Text("Traduit · sur cet appareil")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(translated.map { "Traduction : \($0)" } ?? "Traduction en cours")
    .task(id: "\(messageID)→\(target)") {
      translated = nil
      failure = nil
      if let cached = await TextTranslator.shared.cached(messageID: messageID, target: target) {
        translated = cached
        configuration = nil
        return
      }
      configuration = TranslationSession.Configuration(
        source: source.map { Locale.Language(identifier: $0) },
        target: Locale.Language(identifier: target)
      )
    }
    .translationTask(configuration) { session in
      // La session n'est pas `Sendable` : elle travaille ici, et l'acteur ne
      // reçoit que le résultat.
      do {
        let result = try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw TextTranslator.Failure.unavailable }
        await TextTranslator.shared.store(messageID: messageID, target: target, translation: result)
        translated = result
      } catch {
        failure = (error as? TextTranslator.Failure)?.errorDescription
          ?? "Traduction indisponible \(TranslationPreferences.enFR(target)) sur cet appareil."
      }
    }
  }
}

/// Ce qu'une bulle reçue porte quand sa langue n'est pas celle de l'appareil.
///
/// Les bulles dont on a demandé la traduction, par identifiant de message.
///
/// Hors de la vue exprès : un clic dans le fil fait bouger le magasin
/// (lecture confirmée, non-lus effacés), le fil se redessine, et un `@State`
/// posé dans la bulle repartait à zéro avant d'avoir affiché quoi que ce soit —
/// la transcription vocale n'avait pas ce défaut parce qu'elle relit son cache
/// à chaque apparition. Ici, l'intention de lire vit le temps de la session.
@MainActor
public final class TranslationReveal: ObservableObject {
  public static let shared = TranslationReveal()
  @Published public var revealed: Set<String> = []
  public init() {}
  public func toggle(_ messageID: String, on: Bool) {
    if on { revealed.insert(messageID) } else { revealed.remove(messageID) }
  }
}

/// Trois états, tous locaux : un bouton « Traduire » ; la ligne, quand on l'a
/// demandée ; la ligne d'emblée quand le fil a « Traduire ce qui arrive ». Le
/// réglage arrive par `@AppStorage` sur la clé du fil : changer le sélecteur
/// dans la fiche redessine les bulles à l'instant.
public struct IncomingTranslationSlot: View {
  public let messageID: String
  public let text: String
  /// La langue reconnue — celle qui a valu ce bouton.
  public let source: String
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var font: Font

  @AppStorage private var autoTarget: String
  @ObservedObject private var reveal = TranslationReveal.shared
  private var revealed: Bool { reveal.revealed.contains(messageID) }

  public init(
    messageID: String,
    text: String,
    source: String,
    conversationID: String,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    font: Font
  ) {
    self.messageID = messageID
    self.text = text
    self.source = source
    self.theme = theme
    self.typeface = typeface
    self.font = font
    _autoTarget = AppStorage(wrappedValue: "", TranslationPreferences.incomingKey(conversationID))
  }

  /// La cible du réglage du fil, sauf si la bulle est déjà dans cette langue.
  private var automatic: String? {
    guard !autoTarget.isEmpty, !TextTranslator.sameLanguage(autoTarget, source) else { return nil }
    return autoTarget
  }

  public var body: some View {
    if #available(macOS 15, iOS 18, *) {
      if let target = automatic ?? (revealed ? TextTranslator.deviceLanguage : nil) {
        VStack(alignment: .leading, spacing: 2) {
          TranslationLine(
            messageID: messageID, text: text, source: source, target: target,
            theme: theme, typeface: typeface, font: font
          )
          if automatic == nil {
            Text("Masquer")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.accent)
              .padding(.horizontal, 12)
              .padding(.vertical, 2)
              .contentShape(Rectangle())
              .onTapGesture { reveal.toggle(messageID, on: false) }
              .accessibilityAddTraits(.isButton)
              .accessibilityLabel("Masquer la traduction")
          }
        }
      } else {
        // Un geste, pas un `Button` : sous ce conteneur (menu contextuel,
        // forme de contenu, aide au survol), le bouton `.plain` ne recevait
        // jamais son clic sur le Mac — vérifié en vrai, trace à l'appui —
        // alors que le tap, lui, passe.
        Button {
          reveal.toggle(messageID, on: true)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "character.bubble")
              .font(.system(size: 11, weight: .medium))
            Text("Traduire")
              .font(Typography.meta(typeface))
          }
          .foregroundStyle(theme.accent)
          .padding(.horizontal, 12)
          .frame(height: 22)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Traduire ce message")
      }
    }
  }
}
#endif
