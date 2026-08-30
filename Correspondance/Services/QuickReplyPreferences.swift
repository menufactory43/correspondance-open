import Foundation

/// Le raccourci global de la réponse rapide. Quatre combinaisons proposées —
/// un enregistreur de raccourci complet serait un chantier à lui seul, et
/// quatre touches libres suffisent à ne marcher sur les pieds de personne.
enum QuickReplyHotKey: String, CaseIterable, Identifiable, Sendable {
  case controlOptionSpace
  case controlOptionR
  case controlShiftSpace
  case optionSpace

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .controlOptionSpace: "⌃⌥Espace"
    case .controlOptionR: "⌃⌥R"
    case .controlShiftSpace: "⌃⇧Espace"
    case .optionSpace: "⌥Espace"
    }
  }

  /// Code touche « virtuel » Carbon : 49 = Espace, 15 = R.
  var keyCode: UInt32 {
    switch self {
    case .controlOptionSpace, .controlShiftSpace, .optionSpace: 49
    case .controlOptionR: 15
    }
  }

  /// Masques Carbon : `controlKey` 4096, `optionKey` 2048, `shiftKey` 512.
  var modifiers: UInt32 {
    switch self {
    case .controlOptionSpace: 4096 | 2048
    case .controlOptionR: 4096 | 2048
    case .controlShiftSpace: 4096 | 512
    case .optionSpace: 2048
    }
  }
}

/// Les réglages de la réponse rapide. Tous dans `UserDefaults`, tous lisibles
/// sans instancier quoi que ce soit — les tests s'en servent avec leur propre
/// domaine.
enum QuickReplyPreferences {
  static let enabledKey = "quickReply.enabled"
  static let hotKeyKey = "quickReply.hotKey"
  static let closeAfterSendKey = "quickReply.closeAfterSend"
  static let menuBarExtraKey = "quickReply.menuBarExtra"
  static let avoidFullScreenKey = "quickReply.avoidFullScreen"

  /// Le raccourci global répond, sauf si on le lui a retiré.
  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    value(defaults, enabledKey, default: true)
  }

  static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: enabledKey)
  }

  static func hotKey(in defaults: UserDefaults = .standard) -> QuickReplyHotKey {
    guard let raw = defaults.string(forKey: hotKeyKey),
          let combo = QuickReplyHotKey(rawValue: raw)
    else { return .controlOptionSpace }
    return combo
  }

  static func setHotKey(_ combo: QuickReplyHotKey, in defaults: UserDefaults = .standard) {
    defaults.set(combo.rawValue, forKey: hotKeyKey)
  }

  /// Répondre, c'est en avoir fini : le panneau se referme derrière le message.
  static func closesAfterSend(in defaults: UserDefaults = .standard) -> Bool {
    value(defaults, closeAfterSendKey, default: true)
  }

  static func setClosesAfterSend(_ value: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: closeAfterSendKey)
  }

  /// Icône de barre de menus — éteinte par défaut : une app discrète ne
  /// s'installe pas d'office là-haut.
  static func showsMenuBarExtra(in defaults: UserDefaults = .standard) -> Bool {
    value(defaults, menuBarExtraKey, default: false)
  }

  static func setShowsMenuBarExtra(_ value: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: menuBarExtraKey)
  }

  /// « Jamais au-dessus d'une app plein écran » — éteint par défaut : le
  /// panneau suit alors les bureaux, y compris les plein-écran.
  static func avoidsFullScreen(in defaults: UserDefaults = .standard) -> Bool {
    value(defaults, avoidFullScreenKey, default: false)
  }

  static func setAvoidsFullScreen(_ value: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: avoidFullScreenKey)
  }

  /// Un réglage jamais touché vaut sa valeur d'usine, pas `false`.
  private static func value(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
    guard defaults.object(forKey: key) != nil else { return fallback }
    return defaults.bool(forKey: key)
  }
}
