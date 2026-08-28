import Foundation

enum IMessageSendError: LocalizedError, Sendable {
  case emptyText
  case appleScript(String)

  var errorDescription: String? {
    switch self {
    case .emptyText:
      "Message vide."
    case .appleScript(let detail):
      "Envoi iMessage échoué : \(detail)"
    }
  }
}

/// Envoi via AppleScript → app Messages (fragile, usage perso).
struct IMessageSender: Sendable {
  @MainActor
  func send(text: String, toAddress address: String) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw IMessageSendError.emptyText }

    let escapedText = Self.escapeAppleScript(trimmed)
    let escapedBuddy = Self.escapeAppleScript(address)

    let source = """
    tell application "Messages"
      set targetService to 1st account whose service type = iMessage
      set targetBuddy to participant "\(escapedBuddy)" of targetService
      send "\(escapedText)" to targetBuddy
    end tell
    """

    try await runAppleScript(source)
  }

  @MainActor
  private func runAppleScript(_ source: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error {
          let message = error[NSAppleScript.errorMessage] as? String
            ?? error.description
          continuation.resume(throwing: IMessageSendError.appleScript(message))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private static func escapeAppleScript(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
