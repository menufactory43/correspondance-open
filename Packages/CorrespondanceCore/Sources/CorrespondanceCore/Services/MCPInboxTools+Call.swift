import Foundation

/// Un appel d'outil par son nom, avec des arguments tels qu'un JSON les rend.
///
/// C'est le seul aiguillage : le serveur MCP et la ligne de commande passent
/// tous les deux par ici, avec le même nom d'outil et les mêmes clés. Ce qui
/// est permis se décide **avant**, dans `MCPInbox` — ici on suppose la garde
/// franchie, et on dit ce qui manque quand un argument manque.
extension MCPInboxTools {
  public struct Outcome: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool) {
      self.text = text
      self.isError = isError
    }
  }

  public nonisolated(nonsending) func call(tool: String, arguments: [String: Any]) async -> Outcome {
    let conversation = arguments["conversation"] as? String
    do {
      switch tool {
      case "list_queue":
        return .init(text: try await listQueue(), isError: false)
      case "read_conversation":
        guard let conversation else { return .init(text: "Il manque la conversation à lire.", isError: true) }
        let limite = (arguments["limit"] as? Int) ?? 20
        return .init(text: try await readConversation(conversation, limit: max(1, min(limite, 100))), isError: false)
      case "search":
        guard let query = arguments["query"] as? String else { return .init(text: "Il manque ce qu'on cherche.", isError: true) }
        return .init(text: try await search(query), isError: false)
      case "archive":
        guard let conversation else { return .init(text: "Il manque la conversation à archiver.", isError: true) }
        return .init(text: try await archive(conversation, on: (arguments["on"] as? Bool) ?? true), isError: false)
      case "remind":
        guard let conversation else { return .init(text: "Il manque la conversation.", isError: true) }
        guard let quand = Self.date(in: arguments) else {
          return .init(
            text: "Il manque l'heure du rappel (`at`, en ISO 8601 ou en minutes avec `in_minutes`).",
            isError: true)
        }
        return .init(text: try await remind(conversation, at: quand), isError: false)
      case "draft_reply":
        guard let conversation else { return .init(text: "Il manque la conversation.", isError: true) }
        guard let text = arguments["text"] as? String else { return .init(text: "Il manque le texte.", isError: true) }
        return .init(text: try await draftReply(conversation, text: text), isError: false)
      case "send_message":
        guard let conversation else { return .init(text: "Il manque la conversation.", isError: true) }
        guard let text = arguments["text"] as? String else { return .init(text: "Il manque le texte.", isError: true) }
        return .init(text: try await sendMessage(conversation, text: text), isError: false)
      default:
        return .init(text: "\(tool) : outil inconnu.", isError: true)
      }
    } catch {
      return .init(text: "Le Relais n'a pas répondu : \(error.localizedDescription)", isError: true)
    }
  }

  /// L'heure d'un rappel : un nombre de minutes, ou une date ISO 8601.
  static func date(in arguments: [String: Any], now: Date = Date()) -> Date? {
    if let minutes = arguments["in_minutes"] as? Int {
      return now.addingTimeInterval(TimeInterval(minutes * 60))
    }
    guard let texte = arguments["at"] as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: texte) ?? ISO8601DateFormatter().date(from: texte)
  }
}
