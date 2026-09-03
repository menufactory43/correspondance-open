import Foundation

/// Les trois réactions **réservées** à « cc » : 🤖 📌 🌐. Posées sur une bulle
/// quand un agent est dans le fil, elles ne partent jamais au réseau — l'app
/// les intercepte et envoie à la place un aparté qui cite le message, avec
/// l'instruction en toutes lettres. Sans agent dans le fil, ce sont des emoji
/// comme les autres.
public enum AgentReaction: String, CaseIterable, Sendable {
  /// 🤖 — un brouillon pour ce message.
  case propose = "🤖"
  /// 📌 — retenir ce que ce message dit de la personne, sans répondre.
  case retiens = "📌"
  /// 🌐 — traduire ce message en français.
  case traduis = "🌐"

  /// L'ordre, tel qu'il part en aparté après « @cc ».
  public var instructionFR: String {
    switch self {
    case .propose: "propose une réponse à ce message"
    case .retiens: "retiens ce que dit ce message sur cette personne, sans répondre"
    case .traduis: "traduis ce message en français"
    }
  }

  /// Ce que le sélecteur dit au survol.
  public var helpFR: String {
    switch self {
    case .propose: "Demander un brouillon à cc"
    case .retiens: "cc retient ceci sur cette personne"
    case .traduis: "cc traduit ce message"
    }
  }

  /// La réaction réservée que cet emoji est, ou `nil` s'il est ordinaire.
  /// Tolère la variante avec sélecteur de présentation (`🌐️`).
  public static func reserved(_ emoji: String) -> AgentReaction? {
    let nu = emoji.unicodeScalars.filter { $0.value != 0xFE0F }
    return AgentReaction(rawValue: String(String.UnicodeScalarView(nu)))
  }

  /// Les emoji réservés, dans l'ordre du sélecteur.
  public static var emojis: [String] { allCases.map(\.rawValue) }
}

/// La palette courte du sélecteur de réactions, la même sur le Mac, l'iPhone
/// et Linux : six emoji pour accuser réception, et les trois réservées à
/// l'agent quand il y en a un dans le fil.
public enum QuickReactions {
  public static let base = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

  public static func palette(agentPresent: Bool) -> [String] {
    agentPresent ? base + AgentReaction.emojis : base
  }
}
