import Foundation

/// Ce que la sonde a réellement pu voir dans l'arbre d'accessibilité de Messages.
/// Volontairement plat et `Sendable` : la sonde tourne hors du main actor et
/// son résultat traverse les frontières d'isolation.
struct IMessageAXProbe: Equatable, Sendable {
  /// L'app est autorisée dans Confidentialité → Accessibilité (`AXIsProcessTrusted`).
  var trusted: Bool
  /// Messages.app tourne (lancée par nous ou par l'utilisateur).
  var messagesRunning: Bool
  /// Une vraie fenêtre `AXWindow` a été trouvée (pas le pseudo-élément « application »).
  var windowFound: Bool
  /// La liste des conversations (`CKConversationListCollectionView`) est localisable.
  var sidebarFound: Bool
  /// Le transcript (`TranscriptCollectionView`) est localisable.
  var transcriptFound: Bool
  /// La barre de menus répond (chemin de repli : « Marquer comme non lu », etc.).
  var menuBarFound: Bool
  /// Version du système au moment de la sonde, pour l'afficher dans Réglages.
  var osVersion: String

  init(
    trusted: Bool = false,
    messagesRunning: Bool = false,
    windowFound: Bool = false,
    sidebarFound: Bool = false,
    transcriptFound: Bool = false,
    menuBarFound: Bool = false,
    osVersion: String = IMessageAutomationHealth.currentOSVersion
  ) {
    self.trusted = trusted
    self.messagesRunning = messagesRunning
    self.windowFound = windowFound
    self.sidebarFound = sidebarFound
    self.transcriptFound = transcriptFound
    self.menuBarFound = menuBarFound
    self.osVersion = osVersion
  }
}

/// État de santé de l'automatisation Messages, tel qu'affiché dans Réglages.
/// C'est une machine à états pure : `IMessageAutomationHealth.evaluate(_:enabled:)`
/// ne dépend que de la sonde, donc elle se teste sans Messages.
enum IMessageAutomationHealth: Equatable, Sendable {
  /// Sonde jamais lancée.
  case unknown
  /// Le réglage « Automatisation Messages » est éteint : l'app se comporte comme avant.
  case disabled
  /// Confidentialité → Accessibilité ne nous liste pas (ou plus).
  case accessibilityDenied
  /// Messages.app n'est pas lancée : on la relancera cachée à la première action.
  case messagesNotRunning
  /// `AXIsProcessTrusted()` dit oui mais l'arbre reste opaque — autorisation
  /// périmée (binaire resigné) : il faut retirer puis rajouter l'app dans la liste.
  case treeUnreadable
  /// Arbre lisible mais version de macOS jamais validée : actions proposées « expérimental ».
  case experimental
  /// Tout est en place.
  case ok

  /// Versions majeures de macOS sur lesquelles l'arbre AX a été relevé (`docs/IMESSAGE-AX.md`).
  static let validatedMajorVersions: Set<Int> = [26]

  static var currentOSVersion: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// Majeur d'une version « 26.6.2 ». `nil` si illisible.
  static func majorVersion(of raw: String) -> Int? {
    Int(raw.split(separator: ".").first ?? "")
  }

  /// La machine à états. `enabled` = réglage utilisateur.
  static func evaluate(_ probe: IMessageAXProbe, enabled: Bool) -> IMessageAutomationHealth {
    guard enabled else { return .disabled }
    guard probe.trusted else { return .accessibilityDenied }
    guard probe.messagesRunning else { return .messagesNotRunning }
    // Une fenêtre sans sidebar ni transcript, ou pas de fenêtre du tout alors
    // que Messages tourne : l'arbre ne nous est pas rendu.
    guard probe.windowFound, probe.sidebarFound, probe.transcriptFound else { return .treeUnreadable }
    guard let major = majorVersion(of: probe.osVersion),
          validatedMajorVersions.contains(major)
    else { return .experimental }
    return .ok
  }

  /// Une action d'automatisation peut-elle être tentée dans cet état ?
  var allowsActions: Bool {
    switch self {
    case .ok, .experimental, .messagesNotRunning: true
    case .unknown, .disabled, .accessibilityDenied, .treeUnreadable: false
    }
  }

  /// Faut-il proposer le bouton « Ouvrir Réglages Système → Accessibilité » ?
  var suggestsAccessibilitySettings: Bool {
    self == .accessibilityDenied || self == .treeUnreadable
  }

  func labelFR(osVersion: String = IMessageAutomationHealth.currentOSVersion) -> String {
    switch self {
    case .unknown:
      "Automatisation Messages : jamais sondée."
    case .disabled:
      "Automatisation Messages : désactivée."
    case .accessibilityDenied:
      "Accessibilité manquante — coche Correspondance dans Réglages Système → "
        + "Confidentialité et sécurité → Accessibilité."
    case .messagesNotRunning:
      "Messages n’est pas lancée — elle sera ouverte en arrière-plan à la première action."
    case .treeUnreadable:
      "Arbre AX illisible malgré l’autorisation : elle est périmée. "
        + "Retire puis rajoute Correspondance dans Accessibilité (macOS \(osVersion))."
    case .experimental:
      "Expérimental : arbre AX lisible mais macOS \(osVersion) n’a pas été validée."
    case .ok:
      "Automatisation Messages : OK (macOS \(osVersion) validée)."
    }
  }
}

/// Les erreurs que l'automatisation remonte à l'UI. Aucune n'est silencieuse.
enum IMessageAutomationError: LocalizedError, Sendable, Equatable {
  case disabled
  case unhealthy(IMessageAutomationHealth)
  case messagesUnavailable
  case chatNotFound(String)
  case messageNotFound
  case elementNotFound(String)
  case actionFailed(String)
  case timedOut(String)
  case notConfirmed(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .disabled:
      "Automatisation Messages désactivée — active-la dans Réglages."
    case .unhealthy(let health):
      health.labelFR()
    case .messagesUnavailable:
      "Messages.app est introuvable ou refuse de se lancer en arrière-plan."
    case .chatNotFound(let title):
      "Le fil « \(title) » n’existe pas dans Messages — rien n’a été tenté."
    case .messageNotFound:
      "Ce message n’existe plus dans Messages — rien n’a été tenté."
    case .elementNotFound(let what):
      "Introuvable dans la fenêtre de Messages : \(what)."
    case .actionFailed(let what):
      "Messages a refusé l’action : \(what)."
    case .timedOut(let what):
      "Messages n’a pas répondu en 5 s : \(what)."
    case .notConfirmed(let what):
      "Action envoyée mais non confirmée par chat.db en 3 s : \(what)."
    case .cancelled:
      "Automatisation annulée."
    }
  }
}
