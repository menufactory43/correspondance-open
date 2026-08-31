import Foundation

/// Le délai de grâce avant qu'un message ne parte vraiment.
///
/// La bulle paraît tout de suite — on n'écrit pas contre le réseau — mais rien
/// ne quitte l'appareil avant l'échéance : cliquer « Annuler » d'ici là rend le
/// texte au composer, et le correspondant n'aura jamais rien vu. Passé le
/// délai, le message est parti ; il ne reste alors que la suppression.
///
/// `off` n'est pas un délai nul déguisé : c'est le réglage de qui préfère que
/// « Entrée » veuille dire « parti ».
public enum UndoSendDelay: Int, CaseIterable, Identifiable, Sendable {
  case off = 0
  case three = 3
  case five = 5
  case ten = 10

  public var id: Int { rawValue }

  public var seconds: TimeInterval { TimeInterval(rawValue) }

  public var isOn: Bool { rawValue > 0 }

  public var labelFR: String {
    switch self {
    case .off: "Désactivé"
    case .three: "3 secondes"
    case .five: "5 secondes"
    case .ten: "10 secondes"
    }
  }

  /// Cinq secondes : le temps de relire la phrase qu'on vient d'envoyer, pas
  /// celui de changer d'avis sur ce qu'on voulait dire.
  public static let fallback: UndoSendDelay = .five

  /// Un réglage venu du disque (ou d'une version antérieure) : toute valeur
  /// qu'on ne reconnaît pas retombe sur le défaut plutôt que de couper le geste.
  public static func fromStored(_ raw: Int?) -> UndoSendDelay {
    guard let raw else { return fallback }
    return UndoSendDelay(rawValue: raw) ?? fallback
  }
}
