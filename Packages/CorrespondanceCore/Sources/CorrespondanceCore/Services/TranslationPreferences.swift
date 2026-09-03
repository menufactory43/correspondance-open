import Foundation

/// Ce qu'on traduit dans un fil, et vers quoi — **sur cet appareil**.
///
/// Deux réglages par conversation, dans `UserDefaults` et nulle part ailleurs :
/// « traduire ce qui arrive » (langue cible des bulles reçues) et « traduire ce
/// que j'envoie » (langue vers laquelle passer le brouillon avant l'envoi).
/// Pas sur le Relais, pas dans l'état de salon : c'est un réflexe de la
/// machine qui lit, pas une propriété de la conversation. Le Mac et l'iPhone
/// d'une même personne peuvent donc différer, et c'est voulu — on lit peut-être
/// l'anglais sur l'un et pas sur l'autre.
///
/// Les clés sont publiques : les vues les lisent par `@AppStorage`, pour que
/// changer le sélecteur dans la fiche redessine les bulles sans rien relier.
/// `UserDefaults` est sûr entre files mais ne le dit pas : d'où l'`@unchecked`.
public struct TranslationPreferences: @unchecked Sendable {
  public static let shared = TranslationPreferences()

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public static func incomingKey(_ conversationID: String) -> String {
    "correspondance.translate.incoming.\(conversationID)"
  }

  public static func outgoingKey(_ conversationID: String) -> String {
    "correspondance.translate.outgoing.\(conversationID)"
  }

  /// La langue cible des bulles reçues, ou `nil` : on lit dans la langue d'origine.
  public func incomingTarget(for conversationID: String) -> String? {
    normalized(defaults.string(forKey: Self.incomingKey(conversationID)))
  }

  public func setIncomingTarget(_ code: String?, for conversationID: String) {
    write(normalized(code), key: Self.incomingKey(conversationID))
  }

  /// La langue vers laquelle passer le brouillon avant l'envoi, ou `nil`.
  public func outgoingTarget(for conversationID: String) -> String? {
    normalized(defaults.string(forKey: Self.outgoingKey(conversationID)))
  }

  public func setOutgoingTarget(_ code: String?, for conversationID: String) {
    write(normalized(code), key: Self.outgoingKey(conversationID))
  }

  /// Une chaîne vide vaut « Non » : c'est ce qu'un `Picker` lié à
  /// `@AppStorage` écrit quand on choisit de ne pas traduire.
  private func normalized(_ code: String?) -> String? {
    guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
    return code
  }

  private func write(_ code: String?, key: String) {
    if let code {
      defaults.set(code, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - Les langues proposées

  /// Les langues qu'on propose dans la fiche. Le code est celui que
  /// `Locale.Language` et `NLLanguageRecognizer` partagent — le chinois en
  /// écriture simplifiée, la seule que le sélecteur offre.
  public enum Language: String, CaseIterable, Identifiable, Sendable {
    case french = "fr"
    case english = "en"
    case spanish = "es"
    case portuguese = "pt"
    case german = "de"
    case italian = "it"
    case arabic = "ar"
    case chinese = "zh-Hans"

    public var id: String { rawValue }

    /// « Français », pour un sélecteur.
    public var titleFR: String {
      switch self {
      case .french: "Français"
      case .english: "Anglais"
      case .spanish: "Espagnol"
      case .portuguese: "Portugais"
      case .german: "Allemand"
      case .italian: "Italien"
      case .arabic: "Arabe"
      case .chinese: "Chinois"
      }
    }

    /// « en portugais », pour une phrase.
    public var enFR: String {
      switch self {
      case .french: "en français"
      case .english: "en anglais"
      case .spanish: "en espagnol"
      case .portuguese: "en portugais"
      case .german: "en allemand"
      case .italian: "en italien"
      case .arabic: "en arabe"
      case .chinese: "en chinois"
      }
    }

    /// La langue d'un code, `pt-BR` compris ; `nil` pour une langue qu'on ne
    /// propose pas — le nom générique la remplace alors.
    public static func named(_ code: String) -> Language? {
      let lower = code.lowercased()
      if lower.hasPrefix("zh") { return .chinese }
      let base = String(lower.split(separator: "-").first ?? Substring(lower))
      return allCases.first { $0.rawValue == base }
    }
  }

  /// « en portugais » pour un code connu, « en pt » sinon.
  public static func enFR(_ code: String) -> String {
    Language.named(code)?.enFR ?? "en \(code)"
  }
}
