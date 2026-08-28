import Foundation

enum MessageNetwork: String, CaseIterable, Identifiable, Codable, Sendable {
  case iMessage
  case signal

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .iMessage: "iMessage"
    case .signal: "Signal"
    }
  }

  var systemImage: String {
    switch self {
    case .iMessage: "message.fill"
    case .signal: "antenna.radiowaves.left.and.right"
    }
  }
}
