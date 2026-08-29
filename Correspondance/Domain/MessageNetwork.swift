import Foundation

enum MessageNetwork: String, CaseIterable, Identifiable, Codable, Sendable {
  case iMessage
  case signal
  case whatsapp

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .iMessage: "iMessage"
    case .signal: "Signal"
    case .whatsapp: "WhatsApp"
    }
  }

  var systemImage: String {
    switch self {
    case .iMessage: "message.fill"
    case .signal: "antenna.radiowaves.left.and.right"
    case .whatsapp: "phone.bubble.fill"
    }
  }

  /// Passe par un homeserver Matrix (bridge mautrix) plutôt que par un transport natif.
  var isMatrixBridged: Bool {
    switch self {
    case .iMessage, .signal: false
    case .whatsapp: true
    }
  }

  /// `protocol.id` de l'event d'état `m.bridge` côté mautrix.
  static func fromBridgeProtocol(_ protocolID: String) -> MessageNetwork? {
    switch protocolID.lowercased() {
    case "whatsapp", "whatsappgo": .whatsapp
    default: nil
    }
  }
}
