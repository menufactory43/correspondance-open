import ApplicationServices
import Foundation

enum IMessageSendError: LocalizedError, Sendable {
  case emptyText
  case automationDenied
  case appleScript(String)
  case fileUnreadable(String)

  var errorDescription: String? {
    switch self {
    case .emptyText:
      "Message vide."
    case .fileUnreadable(let name):
      "Fichier illisible : \(name)"
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

    let payload = "\"\(Self.escapeAppleScript(trimmed))\""
    try await run(Self.script(sending: payload, to: .address(address)))
  }

  /// Envoi d'un fichier (image, PDF, n'importe quoi) à un correspondant.
  /// Messages ne sait joindre qu'un fichier *lisible par lui* : on le recopie
  /// d'abord dans un dossier stable du dossier de départ si besoin.
  @MainActor
  func send(fileURL: URL, toAddress address: String) async throws {
    try await sendFile(fileURL, to: .address(address))
  }

  /// Même envoi, mais vers un fil existant — la seule façon d'atteindre un groupe.
  /// `chatGUID` est le `chat.guid` de chat.db (« iMessage;+;chat123… »).
  @MainActor
  func send(fileURL: URL, toChat chatGUID: String) async throws {
    try await sendFile(fileURL, to: .chat(chatGUID))
  }

  @MainActor
  private func sendFile(_ fileURL: URL, to target: Target) async throws {
    let status = permissionStatus(askUser: true)
    if status == .denied { throw IMessageSendError.automationDenied }

    let readable = try Self.readableCopy(of: fileURL)
    let payload = "POSIX file \"\(Self.escapeAppleScript(readable.path))\""
    try await run(Self.script(sending: payload, to: target))
  }

  /// Exécute le script en traduisant le refus d'automatisation en erreur claire.
  @MainActor
  private func run(_ source: String) async throws {
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

  /// Destinataire d'un envoi : un correspondant, ou un fil déjà ouvert.
  enum Target: Sendable {
    case address(String)
    case chat(String)
  }

  /// `payload` est déjà une expression AppleScript (chaîne entre guillemets ou
  /// `POSIX file "…"`) — texte et fichier ne diffèrent que par là.
  static func script(sending payload: String, to target: Target) -> String {
    switch target {
    case .address(let address):
      let buddy = escapeAppleScript(normalizedHandle(address))
      // `participant` (Catalina+) puis `buddy` en repli.
      return """
      tell application "Messages"
        set targetService to 1st account whose service type = iMessage
        try
          set theTarget to participant "\(buddy)" of targetService
        on error
          set theTarget to buddy "\(buddy)" of targetService
        end try
        send \(payload) to theTarget
      end tell
      """
    case .chat(let guid):
      return """
      tell application "Messages"
        set theTarget to chat id "\(escapeAppleScript(guid))"
        send \(payload) to theTarget
      end tell
      """
    }
  }

  /// Dossier des fichiers offerts à Messages. Un fichier hors du dossier de départ
  /// (un temporaire `/var/folders`, un volume externe) peut lui être invisible :
  /// on en dépose une copie ici, sous son nom d'origine.
  static var outgoingDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/Correspondance/Envois", isDirectory: true)
  }

  /// Le fichier tel quel s'il est déjà lisible par Messages, une copie sinon.
  static func readableCopy(of fileURL: URL) throws -> URL {
    let fm = FileManager.default
    guard fm.isReadableFile(atPath: fileURL.path) else {
      throw IMessageSendError.fileUnreadable(fileURL.lastPathComponent)
    }
    if isReachableByMessages(fileURL) { return fileURL }

    do {
      try fm.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true)
      // Un sous-dossier par envoi : deux fichiers homonymes ne se marchent pas dessus.
      let box = outgoingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try fm.createDirectory(at: box, withIntermediateDirectories: true)
      let destination = box.appendingPathComponent(fileURL.lastPathComponent)
      try fm.copyItem(at: fileURL, to: destination)
      return destination
    } catch {
      throw IMessageSendError.fileUnreadable(fileURL.lastPathComponent)
    }
  }

  /// Les dossiers que TCC garde. Messages n'y a aucun droit tant que
  /// l'utilisateur ne le lui a pas donné dans Réglages Système, et un envoi
  /// AppleScript ne peut pas le lui demander : la boîte de dialogue n'a pas de
  /// fenêtre à qui s'adresser. Le fichier part quand même, Messages n'arrive
  /// pas à le lire, et la ligne reste dans `chat.db` en `error = 25`,
  /// `transfer_state = 6` — « Non distribué » dans le fil, sans un mot de plus.
  /// Une capture d'écran, qui atterrit sur le Bureau, tombait exactement là.
  private static let tccGuardedFolders = [
    "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
    // iCloud Drive, et le Bureau/Documents synchronisés qui vivent dessous.
    "Library/Mobile Documents",
  ]

  /// Vrai pour un fichier que Messages saura lire tel quel : dans le dossier de
  /// départ, hors zone temporaire et hors dossiers gardés par TCC.
  static func isReachableByMessages(_ fileURL: URL) -> Bool {
    let path = fileURL.resolvingSymlinksInPath().path
    let home = FileManager.default.homeDirectoryForCurrentUser
      .resolvingSymlinksInPath().path
    guard path.hasPrefix(home + "/") else { return false }
    guard !path.hasPrefix("/private/var/folders/"), !path.hasPrefix("/tmp/") else { return false }
    let relative = String(path.dropFirst(home.count + 1))
    return !tccGuardedFolders.contains { relative == $0 || relative.hasPrefix($0 + "/") }
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
