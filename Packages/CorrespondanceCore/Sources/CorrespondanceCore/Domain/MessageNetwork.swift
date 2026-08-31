import Foundation

public enum MessageNetwork: String, CaseIterable, Identifiable, Codable, Sendable {
  case iMessage
  case signal
  case whatsapp
  case instagram
  /// La note à soi : le seul fil qui ne vienne d'aucun réseau. Il vit dans le
  /// Relais, dans un salon dont on est le seul membre — de quoi se laisser un
  /// mot, une adresse, une photo, et le retrouver sur l'autre appareil.
  case selfNote

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .iMessage: "iMessage"
    case .signal: "Signal"
    case .whatsapp: "WhatsApp"
    case .instagram: "Instagram"
    case .selfNote: "Note à soi"
    }
  }

  public var systemImage: String {
    switch self {
    case .iMessage: "message.fill"
    case .signal: "antenna.radiowaves.left.and.right"
    case .whatsapp: "phone.bubble.fill"
    case .instagram: "camera.fill"
    case .selfNote: "note.text"
    }
  }

  /// Passe par un homeserver Matrix (bridge mautrix) plutôt que par un transport natif.
  /// C'est le descripteur qui fait foi : un réseau bridgé est un réseau qui en a un.
  public var isMatrixBridged: Bool { bridge != nil }

  /// Ce fil passe-t-il par le Relais ? Tous les réseaux bridgés, **et** la note
  /// à soi — qui n'a pas de pont, mais bien un salon. Distinct de
  /// `isMatrixBridged`, qui répond « ce réseau a-t-il un bot à connecter ».
  public var livesOnRelay: Bool { isMatrixBridged || self == .selfNote }

  /// Peut-on modifier un message déjà envoyé sur ce réseau ?
  ///
  /// La capacité vient du descripteur de pont — c'est lui qui sait ce que le
  /// réseau accepte. iMessage l'a aussi, mais par un tout autre chemin
  /// (l'automatisation Messages) : le store le traite à part. La note à soi
  /// est un salon à nous, rien ne s'y oppose.
  public var supportsEditing: Bool {
    if self == .selfNote { return true }
    return bridge?.supportsEditing ?? false
  }

  /// Réseaux bridgés, dans l'ordre de l'enum — ce qui pilote les boutons de Réglages.
  public static var matrixBridged: [MessageNetwork] { allCases.filter(\.isMatrixBridged) }

  /// `protocol.id` de l'event d'état `m.bridge` côté mautrix.
  public static func fromBridgeProtocol(_ protocolID: String) -> MessageNetwork? {
    MatrixBridgeDescriptor.network(ofProtocol: protocolID)
  }
}
