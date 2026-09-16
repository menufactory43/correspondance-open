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

  private init() {
    height = Self.estimate()
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
  }

  /// Le clavier portrait avec sa barre de suggestions, à défaut d'en avoir
  /// vu un : Pro Max et Plus (346), iPhone sans encoche (260), les autres (336).
  private static func estimate() -> CGFloat {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first
    guard let scene else { return 336 }
    let bounds = scene.screen.bounds
    let longSide = max(bounds.width, bounds.height)
    let hasHomeIndicator = (scene.keyWindow?.safeAreaInsets.bottom ?? 0) > 0
    if !hasHomeIndicator { return 260 }
    return longSide >= 920 ? 346 : 336
  }
}
