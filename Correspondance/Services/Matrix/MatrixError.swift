import Foundation

enum MatrixError: LocalizedError, Sendable, Equatable {
  case notConfigured
  case invalidHomeserver(String)
  case http(status: Int, errcode: String?, message: String?)
  case decoding(String)
  case transport(String)
  case whatsAppBotSilent

  var errorDescription: String? {
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
    case .whatsAppBotSilent:
      "Le bot WhatsApp ne répond pas. Vérifie mautrix-whatsapp sur le NUC."
    }
  }

  private static func humanHTTP(status: Int, errcode: String?, message: String?) -> String {
    switch errcode {
    case "M_FORBIDDEN":
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
