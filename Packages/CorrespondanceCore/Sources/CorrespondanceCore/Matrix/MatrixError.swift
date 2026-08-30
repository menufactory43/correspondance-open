import Foundation

public enum MatrixError: LocalizedError, Sendable, Equatable {
  case notConfigured
  case invalidHomeserver(String)
  case http(status: Int, errcode: String?, message: String?)
  case decoding(String)
  case transport(String)
  case bridgeBotSilent(MessageNetwork)
  /// Le bot n'a pas accepté l'invitation au salon de gestion : Synapse ne le connaît pas.
  case bridgeBotNotJoined(MessageNetwork)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "Matrix : pas encore connecté. Renseigne le homeserver dans Réglages."
    case .invalidHomeserver(let raw):
      "Adresse de homeserver invalide : \(raw)"
    case .http(let status, let errcode, let message):
      Self.humanHTTP(status: status, errcode: errcode, message: message)
    case .decoding(let detail):
      "Réponse Matrix incompréhensible : \(detail)"
    case .transport(let detail):
      "Le homeserver ne répond pas : \(detail)"
    case .bridgeBotSilent(let network):
      "Le bot \(network.labelFR) ne répond pas. Vérifie le pont sur le NUC."
    case .bridgeBotNotJoined(let network):
      "Le bot \(network.labelFR) n'a pas rejoint le salon : Synapse n'a pas chargé la registration du pont. Sur le NUC : docker-compose restart synapse, puis Relancer."
    }
  }

  private static func humanHTTP(status: Int, errcode: String?, message: String?) -> String {
    switch errcode {
    case "M_FORBIDDEN":
      // Le même code couvre « mauvais mot de passe » et « pas membre du salon » :
      // on relaie la raison du serveur plutôt qu'un diagnostic inventé.
      if let message, !message.isEmpty { return "Refusé par le homeserver : \(message)" }
      return "Identifiants Matrix refusés."
    case "M_UNKNOWN_TOKEN":
      return "Session Matrix expirée — reconnecte-toi dans Réglages."
    case "M_LIMIT_EXCEEDED":
      return "Le homeserver limite les requêtes — réessaie dans un instant."
    case "M_NOT_FOUND":
      return "Ressource Matrix introuvable."
    default:
      let detail = message ?? errcode ?? "code \(status)"
      return "Matrix (\(status)) : \(detail)"
    }
  }
}
