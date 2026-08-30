import Foundation

/// Focus = défaut zen ; Inbox = liste + fil type Beeper.
public enum InboxMode: String, CaseIterable, Identifiable, Sendable {
  case focus
  case inbox

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .focus: "Focus"
    case .inbox: "Inbox"
    }
  }

  public var systemImage: String {
    switch self {
    case .focus: "rectangle.portrait.and.arrow.right"
    case .inbox: "tray.full"
    }
  }
}
