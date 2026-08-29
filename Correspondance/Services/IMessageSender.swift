import ApplicationServices
import Foundation

enum IMessageSendError: LocalizedError, Sendable {
  case emptyText
  case automationDenied
  case appleScript(String)

  var errorDescription: String? {
    switch self {
    case .emptyText:
      "Message vide."
    case .automationDenied:
      "Messages refuse l’automatisation. Réglages Système → Confidentialité → Automatisation → coche Correspondance pour Messages."
    case .appleScript(let detail):
      "Envoi iMessage échoué : \(detail)"
    }
  }
}

/// Envoi via AppleScript → app Messages.
/// Il faut l’entitlement `automation.apple-events` + `NSAppleEventsUsageDescription`
/// (comme Beeper) sinon Hardened Runtime bloque l’envoi sans boîte de permission.
struct IMessageSender: Sendable {
  /// Bundle id de l’app Messages sur macOS.
  private static let messagesBundleID = "com.apple.MobileSMS"

  @MainActor
  func requestAutomationAccess() -> Bool {
    permissionStatus(askUser: true) == .authorized
  }

  @MainActor
  func automationAuthorized() -> Bool {
    permissionStatus(askUser: false) == .authorized
  }

  @MainActor
  func send(text: String, toAddress address: String) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw IMessageSendError.emptyText }

    let status = permissionStatus(askUser: true)
    if status == .denied {
      throw IMessageSendError.automationDenied
    }

    let escapedText = Self.escapeAppleScript(trimmed)
    let escapedBuddy = Self.escapeAppleScript(Self.normalizedHandle(address))

    // `participant` (Catalina+) puis `buddy` en repli.
    let source = """
    tell application "Messages"
      set targetService to 1st account whose service type = iMessage
      try
        set targetBuddy to participant "\(escapedBuddy)" of targetService
      on error
        set targetBuddy to buddy "\(escapedBuddy)" of targetService
      end try
      send "\(escapedText)" to targetBuddy
    end tell
    """

    do {
      try await runAppleScript(source)
    } catch let IMessageSendError.appleScript(detail)
      where detail.localizedCaseInsensitiveContains("not authorized")
      || detail.localizedCaseInsensitiveContains("not authorised")
      || detail.localizedCaseInsensitiveContains("errAEEventNotPermitted")
    {
      throw IMessageSendError.automationDenied
    }
  }

  @MainActor
  private func permissionStatus(askUser: Bool) -> AutomationStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: Self.messagesBundleID)
    let status = AEDeterminePermissionToAutomateTarget(
      target.aeDesc,
      typeWildCard,
      typeWildCard,
      askUser
    )
    switch status {
    case 0:
      return .authorized
    case OSStatus(errAEEventNotPermitted):
      return .denied
    default:
      return .unknown
    }
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

  private static func normalizedHandle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed }
    return trimmed
  }

  private static func escapeAppleScript(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

private enum AutomationStatus {
  case authorized
  case denied
  case unknown
}
