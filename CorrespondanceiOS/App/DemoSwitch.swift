import SwiftUI

/// Entrer ou sortir du mode démonstration depuis l'interface.
///
/// Le mode démo existait déjà, mais seulement par argument de lancement : un
/// relecteur de l'App Store, ou quelqu'un qui n'a pas encore de Relais, se
/// heurtait à un écran de connexion sans issue. La bascule remplace le magasin
/// entier (`RelayStore(demo:)`) : rien de réel ne se mêle à la démonstration.
struct DemoSwitchKey: EnvironmentKey {
  static let defaultValue: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
  var demoSwitch: @MainActor (Bool) -> Void {
    get { self[DemoSwitchKey.self] }
    set { self[DemoSwitchKey.self] = newValue }
  }
}
