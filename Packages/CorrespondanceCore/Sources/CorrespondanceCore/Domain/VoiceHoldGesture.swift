import Foundation

/// Ce que le doigt décide pendant qu'on maintient le micro, façon WhatsApp :
/// on parle tant qu'on tient, on glisse à gauche pour renoncer, vers le haut
/// pour poser le doigt et continuer sans lui.
///
/// Les seuils vivent ici plutôt que dans la vue : c'est la règle du geste, et
/// elle se vérifie sans écran.
public enum VoiceHoldGesture {
  /// Assez loin pour qu'aucun tremblement de pouce n'abandonne un message.
  public static let threshold: CGFloat = 80
  /// En deçà, ce n'était pas un maintien mais une tape : rien ne part, rien
  /// ne reste — le micro se tient, il ne se tape pas.
  public static let tapDuration: TimeInterval = 0.35

  public enum Outcome: Equatable {
    /// On tient toujours : l'enregistrement court.
    case recording
    /// Glissé vers la gauche : le vocal part à la corbeille.
    case cancelled
    /// Glissé vers le haut : le doigt peut se lever, la bande reste.
    case locked
  }

  /// La direction franche l'emporte : un geste en diagonale ne verrouille pas
  /// ET n'annule pas — c'est le plus grand des deux écarts qui tranche.
  public static func outcome(translation: CGSize) -> Outcome {
    let left = -translation.width
    let up = -translation.height
    if up >= threshold, up >= left { return .locked }
    if left >= threshold { return .cancelled }
    return .recording
  }
}
