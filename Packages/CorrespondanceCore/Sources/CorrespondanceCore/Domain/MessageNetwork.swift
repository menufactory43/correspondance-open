import Foundation

public enum MessageNetwork: String, CaseIterable, Identifiable, Codable, Sendable {
  case iMessage
  case signal
  case whatsapp
  case instagram

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .iMessage: "iMessage"
    case .signal: "Signal"
    case .whatsapp: "WhatsApp"
    case .instagram: "Instagram"
    }
  }

  public var systemImage: String {
    switch self {
    case .iMessage: "message.fill"
    case .signal: "antenna.radiowaves.left.and.right"
    case .whatsapp: "phone.bubble.fill"
    case .instagram: "camera.fill"
    }
  }

  /// Passe par un homeserver Matrix (bridge mautrix) plutôt que par un transport natif.
  /// C'est le descripteur qui fait foi : un réseau bridgé est un réseau qui en a un.
  public var isMatrixBridged: Bool { bridge != nil }

  /// Réseaux bridgés, dans l'ordre de l'enum — ce qui pilote les boutons de Réglages.
  public static var matrixBridged: [MessageNetwork] { allCases.filter(\.isMatrixBridged) }

  /// `protocol.id` de l'event d'état `m.bridge` côté mautrix.
  public static func fromBridgeProtocol(_ protocolID: String) -> MessageNetwork? {
    MatrixBridgeDescriptor.network(ofProtocol: protocolID)
  }
}
