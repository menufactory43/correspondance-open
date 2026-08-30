import Foundation

/// État d'acheminement du dernier message sortant, quand le réseau l'expose.
/// iMessage le donne (`is_delivered` / `is_read`) ; Signal et WhatsApp non — on n'affiche rien.
public enum MessageDelivery: String, Codable, Sendable, Hashable, CaseIterable {
  case sending
  case sent
  case delivered
  case read

  public var systemImage: String {
    switch self {
    case .sending: "clock"
    case .sent: "checkmark"
    case .delivered: "checkmark.circle"
    case .read: "checkmark.circle.fill"
    }
  }

  public var labelFR: String {
    switch self {
    case .sending: "Envoi…"
    case .sent: "Envoyé"
    case .delivered: "Livré"
    case .read: "Vu"
    }
  }
}
