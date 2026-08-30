import Carbon.HIToolbox
import Foundation

/// Le raccourci qui appelle la réponse rapide, où qu'on soit.
///
/// `RegisterEventHotKey` plutôt qu'un moniteur global d'événements : Carbon ne
/// demande AUCUNE autorisation d'accessibilité, là où `addGlobalMonitorForEvents`
/// obligerait à envoyer l'utilisateur dans Réglages Système avant la première
/// frappe. Un raccourci à la fois — celui des réglages.
@MainActor
final class GlobalHotKey {
  static let shared = GlobalHotKey()

  /// Signature de l'app pour Carbon : « CRQP » (Correspondance Quick Panel).
  private static let signature: OSType = 0x4352_5150

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private var registered: QuickReplyHotKey?
  private var action: (() -> Void)?

  private init() {}

  /// Le raccourci en vigueur, ou `nil` s'il est éteint.
  var currentCombo: QuickReplyHotKey? { registered }

  /// Pose (ou repose) le raccourci. Rappeler avec la même combinaison ne fait rien.
  func register(_ combo: QuickReplyHotKey, action: @escaping () -> Void) {
    self.action = action
    guard registered != combo else { return }
    unregister()
    installHandlerIfNeeded()

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: 1)
    let status = RegisterEventHotKey(
      combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref
    )
    guard status == noErr, let ref else { return }
    hotKeyRef = ref
    registered = combo
  }

  func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    hotKeyRef = nil
    registered = nil
  }

  /// Appelé depuis le gestionnaire Carbon, sur la file principale.
  fileprivate func fire() {
    action?()
  }

  private func installHandlerIfNeeded() {
    guard handlerRef == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    // Le gestionnaire est une fonction C : elle ne capture rien et repasse par
    // le singleton. Carbon la sert sur la boucle principale.
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ -> OSStatus in
        var id = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &id
        )
        guard id.signature == GlobalHotKey.signature else { return noErr }
        MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
        return noErr
      },
      1,
      &spec,
      nil,
      &handlerRef
    )
  }
}
