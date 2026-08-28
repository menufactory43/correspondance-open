import Foundation

/// Focus = défaut zen ; Inbox = liste + fil type Beeper.
enum InboxMode: String, CaseIterable, Identifiable, Sendable {
  case focus
  case inbox

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .focus: "Focus"
    case .inbox: "Inbox"
    }
  }

  var systemImage: String {
    switch self {
    case .focus: "rectangle.portrait.and.arrow.right"
    case .inbox: "tray.full"
    }
  }
}
