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
  /// `AXWindows` a répondu, mais avec des pseudo-éléments de rôle `AXApplication`
  /// à la place des fenêtres. Observé sur macOS 26.6.2 pour TOUTES les apps à la
  /// fois (Finder, le terminal lui-même…) alors que TCC accorde bien l'accès :
  /// c'est le serveur d'accessibilité de la session qui ne rend plus les fenêtres,
  /// pas notre autorisation. Se déconnecter/reconnecter le remet d'aplomb.
  var pseudoWindows: Bool
  /// Version du système au moment de la sonde, pour l'afficher dans Réglages.
  var osVersion: String

  init(
    trusted: Bool = false,
    messagesRunning: Bool = false,
    windowFound: Bool = false,
    sidebarFound: Bool = false,
    transcriptFound: Bool = false,
    menuBarFound: Bool = false,
    pseudoWindows: Bool = false,
    osVersion: String = IMessageAutomationHealth.currentOSVersion
  ) {
    self.trusted = trusted
    self.messagesRunning = messagesRunning
    self.windowFound = windowFound
    self.sidebarFound = sidebarFound
    self.transcriptFound = transcriptFound
    self.menuBarFound = menuBarFound
    self.pseudoWindows = pseudoWindows
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
  /// Autorisation en place, barre de menus lisible, mais le serveur d'accessibilité
  /// de la session ne rend plus les fenêtres (à personne) : session à rouvrir.
  case axServerUnavailable
  /// `AXIsProcessTrusted()` dit oui mais fenêtre, sidebar ou transcript restent
  /// introuvables : pas de fenêtre Messages ouverte, identifiants inconnus, ou
  /// autorisation périmée (binaire resigné) — dans cet ordre de probabilité.
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
    // Les menus se lisent mais les fenêtres reviennent en pseudo-éléments :
    // c'est la session, pas nous.
    if probe.menuBarFound, probe.pseudoWindows, !probe.windowFound { return .axServerUnavailable }
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
    case .unknown, .disabled, .accessibilityDenied, .axServerUnavailable, .treeUnreadable: false
    }
  }

  /// Faut-il proposer le bouton « Ouvrir Réglages Système → Accessibilité » ?
  var suggestsAccessibilitySettings: Bool {
    self == .accessibilityDenied || self == .treeUnreadable
  }

  func labelFR(osVersion: String = IMessageAutomationHealth.currentOSVersion) -> String {
    switch self {
    case .unknown:
      "Pas encore vérifié."
    case .disabled:
      "Désactivé."
    case .accessibilityDenied:
      "Il manque l’autorisation d’Accessibilité. Coche Correspondance dans Réglages Système, "
        + "Confidentialité et sécurité, Accessibilité."
    case .messagesNotRunning:
      "Messages n’est pas ouvert. Il s’ouvrira en arrière-plan au premier geste."
    case .axServerUnavailable:
      "L’autorisation est là, mais le Mac ne répond plus. "
        + "Ferme ta session et rouvre-la, puis vérifie à nouveau."
    case .treeUnreadable:
      "La fenêtre de Messages reste introuvable. Ouvre-en une (⌘N) et vérifie à nouveau. "
        + "Si ça continue, retire puis remets Correspondance dans Accessibilité."
    case .experimental:
      "Ça marche, mais macOS \(osVersion) n’a pas encore été testée."
    case .ok:
      "Tout est en place (macOS \(osVersion))."
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
      "Le pilotage de Messages est désactivé. Active-le dans Réglages."
    case .unhealthy(let health):
      health.labelFR()
    case .messagesUnavailable:
      "Messages.app est introuvable ou refuse de se lancer en arrière-plan."
    case .chatNotFound(let title):
      "La conversation « \(title) » n’existe pas dans Messages."
    case .messageNotFound:
      "Ce message n’existe plus dans Messages."
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
