// Sous Linux, pas de NaturalLanguage : pas de traduction locale.
#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Lire un message dans une autre langue que la sienne — sur l'appareil.
///
/// Deux choses seulement vivent ici : **reconnaître** la langue d'un texte
/// (`NLLanguageRecognizer`, sans réseau) et **se souvenir** des traductions
/// déjà faites, par message. La traduction elle-même passe par le framework
/// `Translation` d'Apple, dont la session ne s'obtient que par un modificateur
/// SwiftUI (`.translationTask`) : c'est la vue `TranslationLine` qui la tient,
/// et qui dépose le résultat ici. Rien ne part nulle part : ni au Relais, ni
/// à cc, ni chez Apple — les modèles de langue sont téléchargés par le
/// système, une fois, puis tournent sur la machine.
///
/// Le même code sur le Mac et sur l'iPhone.
public actor TextTranslator {
  public static let shared = TextTranslator()

  public enum Failure: LocalizedError, Equatable {
    case unavailable
    case empty

    public var errorDescription: String? {
      switch self {
      case .unavailable: "Traduction indisponible pour cette langue sur cet appareil."
      case .empty: "Rien à traduire."
      }
    }
  }

  /// En dessous, on ne se prononce pas : « ok », « Merci ! », un emoji — le
  /// reconnaisseur hésite, et un bouton « Traduire » sous « Carrément. »
  /// ferait rire.
  public static let minimumLength = 12

  /// La confiance en dessous de laquelle on préfère se taire. Sur une phrase
  /// entière, le reconnaisseur donne 0,98 et plus ; un mot ambigu descend
  /// sous 0,3.
  public static let confidenceThreshold = 0.6

  /// Ce qu'on a déjà traduit, par message et par langue cible : une
  /// traduction coûte, on ne la refait pas parce qu'une bulle a redessiné.
  private var cache: [String: String] = [:]

  public init() {}

  private static func key(_ messageID: String, _ target: String) -> String {
    "\(messageID)→\(base(target))"
  }

  public func cached(messageID: String, target: String) -> String? {
    cache[Self.key(messageID, target)]
  }

  /// Déposer une traduction faite ailleurs (par la session SwiftUI).
  public func store(messageID: String, target: String, translation: String) {
    cache[Self.key(messageID, target)] = translation
  }

  public func forget(messageID: String) {
    let prefix = "\(messageID)→"
    for key in cache.keys where key.hasPrefix(prefix) { cache.removeValue(forKey: key) }
  }

  /// La traduction d'un message, par le cache d'abord, par `engine` sinon.
  ///
  /// `engine` est ce que la session `Translation` sait faire — la vue le
  /// passe, puisque la session ne vit que chez elle et n'est pas `Sendable`.
  /// Le résultat est mis en cache sous l'identifiant du message.
  public func translate(
    messageID: String,
    text: String,
    to target: String,
    using engine: @MainActor (String) async throws -> String
  ) async throws -> String {
    if let cached = cache[Self.key(messageID, target)] { return cached }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.empty }
    let translated = try await engine(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !translated.isEmpty else { throw Failure.unavailable }
    cache[Self.key(messageID, target)] = translated
    return translated
  }

  // MARK: - Reconnaître la langue

  /// La détection est synchrone et sans acteur : la bulle la demande en
  /// dessinant, et un `await` par bulle ferait clignoter le fil. Elle est
  /// mémorisée par texte — le reconnaisseur repasse sinon sur les quatre
  /// cents bulles d'un groupe à chaque accusé de lecture.
  nonisolated(unsafe) private static let detections = NSCache<NSString, NSString>()

  /// La langue d'un texte (`fr`, `pt`, `zh-Hans`…), ou `nil` quand on ne sait
  /// pas assez pour le dire : trop court, sans lettres, ou reconnaisseur hésitant.
  public nonisolated static func language(of text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumLength,
          trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
    else { return nil }
    if let known = detections.object(forKey: trimmed as NSString) {
      return known.length == 0 ? nil : known as String
    }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(trimmed)
    let best = recognizer.languageHypotheses(withMaximum: 1).max { $0.value < $1.value }
    let found = best.flatMap { $0.value >= confidenceThreshold ? $0.key.rawValue : nil }
    detections.setObject((found ?? "") as NSString, forKey: trimmed as NSString)
    return found
  }

  /// La langue de l'appareil — celle dans laquelle on lit ici.
  ///
  /// `Locale.preferredLanguages`, pas `Locale.current` : ce dernier se plie
  /// aux localisations que l'app déclare, et une app sans `fr` répond « en »
  /// sur un Mac réglé en français — d'où « Traduire » sous du français.
  public nonisolated static var deviceLanguage: String {
    let prefere = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
    return prefere ?? Locale.current.language.languageCode?.identifier ?? "fr"
  }

  /// La langue d'un texte quand elle n'est **pas** celle de l'appareil : ce
  /// qui vaut un bouton « Traduire ». `nil` sinon.
  public nonisolated static func foreignLanguage(of text: String) -> String? {
    guard let found = language(of: text), !sameLanguage(found, deviceLanguage) else { return nil }
    return found
  }

  /// `pt` et `pt-BR` sont la même langue ; `zh-Hans` et `zh-Hant`, deux écritures.
  public nonisolated static func base(_ code: String) -> String {
    let lower = code.lowercased()
    if lower.hasPrefix("zh") { return lower }
    return String(lower.split(separator: "-").first ?? Substring(lower))
  }

  public nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
    base(a) == base(b)
  }
}
#endif
