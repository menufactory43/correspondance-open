import SwiftUI
import UIKit

/// La hauteur du vrai clavier, retenue pour toute l'app, bord d'écran
/// compris : celle que le plateau des médias prend pour le remplacer sans
/// que le composer bouge d'un point.
///
/// Elle vivait dans chaque composer, à 336 tant que le clavier n'y était pas
/// venu. Ouvrir un fil et taper « + » d'abord posait donc un plateau à la
/// hauteur d'un iPhone standard — trop bas sur un Pro Max, trop haut sur un
/// SE, faux dès que la barre de suggestions est cachée — et la croix faisait
/// sauter le composer en rendant le clavier à sa vraie hauteur. Une seule
/// mémoire, nourrie par chaque clavier de l'app, et qui ignore le plateau
/// lui-même : en tant qu'`inputView`, il se déclare aussi en clavier.
@MainActor @Observable
final class KeyboardHeightMemory {
  static let shared = KeyboardHeightMemory()

  /// La dernière hauteur vue d'un vrai clavier logiciel, ou une estimation
  /// d'après l'écran tant qu'aucun n'est venu.
  private(set) var height: CGFloat

  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  /// La dernière hauteur mesurée, d'un lancement à l'autre : le premier « + »
  /// d'une session n'a pas à deviner ce que le clavier a déjà dit hier.
  private static let storageKey = "keyboardHeight.last"

  private init() {
    let remembered = UserDefaults.standard.double(forKey: Self.storageKey)
    height = remembered > 150 ? remembered : Self.estimate()
    for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
          let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
          let isLocal = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool ?? true
          MainActor.assumeIsolated {
            Self.shared.record(frame: frame, isLocal: isLocal)
          }
        }
      )
    }
  }

  private func record(frame: CGRect?, isLocal: Bool) {
    // Le plateau qui monte se déclare en clavier : ce n'est pas lui qu'on mesure.
    guard isLocal, !MediaTrayPresence.isPresentingTray, let frame else { return }
    // Un clavier matériel ne laisse qu'une barre ; un clavier rangé, rien.
    guard frame.height > 150, frame.height != height else { return }
    // Un clavier en train de se ranger « change de cadre » vers le bas de
    // l'écran : sa hauteur est toujours la sienne, on peut la garder.
    height = frame.height
    UserDefaults.standard.set(Double(frame.height), forKey: Self.storageKey)
  }

  /// Le clavier portrait avec sa barre de suggestions, à défaut d'en avoir
  /// vu un : Pro Max et Plus (346), iPhone à bouton d'accueil (260), les
  /// autres (336). Dans le doute, 336 : un plateau trop court fait déborder
  /// la pellicule derrière le composer, un plateau trop haut ne gêne personne.
  private static func estimate() -> CGFloat {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
          let window = scene.keyWindow ?? scene.windows.first
    else { return 336 }
    if window.safeAreaInsets.bottom == 0 { return 260 }
    let longSide = max(scene.screen.bounds.width, scene.screen.bounds.height)
    return longSide >= 920 ? 346 : 336
  }
}
