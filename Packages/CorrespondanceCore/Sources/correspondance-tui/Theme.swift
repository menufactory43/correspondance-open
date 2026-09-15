import CorrespondanceCore
import CorrespondanceTerminal
import Foundation

/// Les couleurs et les glyphes de la TUI.
///
/// Rien en 24 bits : le fond et le texte sont ceux du terminal, et les
/// accents viennent des seize couleurs de sa palette. La TUI prend ainsi le
/// thème de l'utilisateur — clair, sombre, transparent — sans rien régler.
enum Theme {
  static let text = Style.plain
  static let muted = Style(attributes: .dim)
  static let strong = Style(attributes: .bold)
  static let accent = Style(foreground: .blue)
  static let accentStrong = Style(foreground: .blue, attributes: .bold)
  static let warning = Style(foreground: .yellow)
  static let danger = Style(foreground: .red)
  static let success = Style(foreground: .green)
  static let agent = Style(foreground: .magenta)
  static let border = Style(foreground: .brightBlack)
  static let selectionMarker = Style(foreground: .blue, attributes: .bold)
  static let inactiveMarker = Style(foreground: .brightBlack)
  static let link = Style(foreground: .blue, attributes: .underline)

  static func network(_ network: MessageNetwork) -> Style {
    switch network {
    case .signal: Style(foreground: .blue)
    case .whatsapp: Style(foreground: .green)
    case .instagram: Style(foreground: .magenta)
    case .messenger: Style(foreground: .cyan)
    case .twitter: Style(attributes: .bold)
    case .slack: Style(foreground: .yellow)
    case .telegram: Style(foreground: .brightCyan)
    case .iMessage: Style(foreground: .brightBlue)
    case .selfNote: Style(foreground: .brightBlack)
    case .agent: Style(foreground: .magenta)
    }
  }

  static func networkTag(_ network: MessageNetwork) -> String {
    switch network {
    case .signal: "Signal"
    case .whatsapp: "WhatsApp"
    case .instagram: "Insta"
    case .messenger: "Messenger"
    case .twitter: "X"
    case .slack: "Slack"
    case .telegram: "Telegram"
    case .iMessage: "iMessage"
    case .selfNote: "Note"
    case .agent: "cc"
    }
  }

  /// Une couleur stable par expéditeur, dans un groupe.
  static func sender(_ name: String) -> Style {
    let palette: [TerminalColor] = [.cyan, .green, .magenta, .yellow, .brightBlue, .brightRed, .brightGreen, .brightMagenta]
    let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
    return Style(foreground: palette[Int(hash % UInt32(palette.count))], attributes: .bold)
  }

  enum Box {
    static let horizontal = "─"
    static let vertical = "│"
    static let topLeft = "╭"
    static let topRight = "╮"
    static let bottomLeft = "╰"
    static let bottomRight = "╯"
  }
}

/// Les dates, dites comme on les dit.
enum Dates {
  private static let locale = Locale(identifier: "fr_FR")

  private static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private static let weekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "EEEE"
    return formatter
  }()

  private static let dayMonth: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "d MMM"
    return formatter
  }()

  private static let full: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "d MMM yyyy"
    return formatter
  }()

  static func clock(_ date: Date) -> String { time.string(from: date) }

  /// Un moment à venir : « 18:00 » aujourd'hui, « lun 09:00 » ensuite.
  static func moment(_ date: Date) -> String {
    Calendar.current.isDateInToday(date) ? clock(date) : "\(listStamp(date)) \(clock(date))"
  }

  /// Pour la liste : l'heure aujourd'hui, « hier », le jour de la semaine, puis la date.
  static func listStamp(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return time.string(from: date) }
    if calendar.isDateInYesterday(date) { return "hier" }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
      return String(weekday.string(from: date).prefix(3))
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return dayMonth.string(from: date) }
    return full.string(from: date)
  }

  /// Pour les séparateurs du fil.
  static func separator(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let clock = time.string(from: date)
    if calendar.isDateInToday(date) { return "Aujourd’hui \(clock)" }
    if calendar.isDateInYesterday(date) { return "Hier \(clock)" }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
      return "\(weekday.string(from: date).capitalized) \(clock)"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      return "\(dayMonth.string(from: date)) \(clock)"
    }
    return "\(full.string(from: date)) \(clock)"
  }

  static func duration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
