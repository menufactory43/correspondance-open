import Foundation

/// « Quand ? » — comprend une date écrite comme on la dirait, en français.
///
/// Beeper accepte « Monday morning » ou « in 3 weeks » et propose une poignée
/// de raccourcis (« In an Hour », « Tomorrow », « This Weekend »…). On fait
/// pareil, en français, sans dépendre de la locale système : les tables de
/// mots sont ici, et tout est calculable avec une horloge et un calendrier
/// fournis — donc testable.
public enum SendLaterTime {
  /// Heures « de convention » derrière les mots du quotidien.
  public enum Moment {
    public static let morning = 9
    public static let noon = 12
    public static let afternoon = 14
    public static let evening = 18
  }

  public struct Suggestion: Identifiable, Equatable, Sendable {
    public let title: String
    public let date: Date
    public var id: String { title }
  }

  // MARK: - Suggestions

  /// Raccourcis proposés à vide, dans l'ordre. Ceux déjà passés disparaissent
  /// (« Ce soir » n'a pas de sens à 22 h).
  public static func suggestions(now: Date = Date(), calendar: Calendar = .current) -> [Suggestion] {
    var result: [Suggestion] = []
    func add(_ title: String, _ date: Date?) {
      guard let date, date > now else { return }
      guard !result.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 }) else { return }
      result.append(Suggestion(title: title, date: date))
    }
    add("Dans une heure", now.addingTimeInterval(3_600))
    add("Dans deux heures", now.addingTimeInterval(7_200))
    add("Ce soir", at(hour: Moment.evening, minute: 0, on: now, calendar: calendar))
    add("Demain matin", at(hour: Moment.morning, minute: 0, on: day(1, from: now, calendar: calendar), calendar: calendar))
    add("Ce week-end", at(hour: 10, minute: 0, on: nextWeekday(7, from: now, calendar: calendar, allowToday: false), calendar: calendar))
    add("Lundi matin", at(hour: Moment.morning, minute: 0, on: nextWeekday(2, from: now, calendar: calendar, allowToday: false), calendar: calendar))
    return result
  }

  // MARK: - Analyse

  /// `nil` si rien de compréhensible, ou si la date obtenue est déjà passée.
  public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
    let text = fold(input)
    guard !text.isEmpty else { return nil }

    var tokens = text.split(separator: " ").map(String.init)
    // Mots creux : « à », « le », « prochain », « vers »…
    tokens.removeAll { ["a", "le", "la", "les", "vers", "pour", "prochain", "prochaine", "de", "du", "en", "au"].contains($0) }
    guard !tokens.isEmpty else { return nil }

    // « dans 2h », « dans 30 min », « dans 3 jours », « dans une semaine ».
    if tokens.first == "dans" {
      return relative(Array(tokens.dropFirst()), now: now, calendar: calendar)
    }

    var dayBase: Date? = nil
    var hour: Int? = nil
    var minute = 0
    var explicitDay = false

    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      defer { index += 1 }

      if let (h, m) = clockTime(token) {
        hour = h
        minute = m
        continue
      }
      // « 14 h 30 » éclaté en trois mots ; « 14 h ».
      if let h = Int(token), (0...23).contains(h), index + 1 < tokens.count, tokens[index + 1] == "h" {
        hour = h
        index += 1
        if index + 1 < tokens.count, let m = Int(tokens[index + 1]), (0...59).contains(m) {
          minute = m
          index += 1
        }
        continue
      }
      if let moment = momentHour(token) {
        if hour == nil { hour = moment }
        // « soir » seul = ce soir ; « matin » seul = demain matin si déjà passé.
        continue
      }
      switch token {
      case "aujourd'hui", "aujourdhui", "auj":
        dayBase = now; explicitDay = true
      case "demain":
        dayBase = day(1, from: now, calendar: calendar); explicitDay = true
      case "apres-demain", "apresdemain", "surlendemain":
        dayBase = day(2, from: now, calendar: calendar); explicitDay = true
      case "ce", "cette":
        continue
      case "week-end", "weekend", "we":
        dayBase = nextWeekday(7, from: now, calendar: calendar, allowToday: true)
        if hour == nil { hour = 10 }
        explicitDay = true
      case "semaine":
        // « la semaine prochaine » → lundi.
        dayBase = nextWeekday(2, from: now, calendar: calendar, allowToday: false)
        if hour == nil { hour = Moment.morning }
        explicitDay = true
      case "mois":
        dayBase = calendar.date(byAdding: .month, value: 1, to: now)
        if hour == nil { hour = Moment.morning }
        explicitDay = true
      default:
        if let weekday = weekday(token) {
          dayBase = nextWeekday(weekday, from: now, calendar: calendar, allowToday: true)
          explicitDay = true
        } else if let date = calendarDay(tokens, at: &index, now: now, calendar: calendar) {
          dayBase = date
          explicitDay = true
        } else {
          return nil
        }
      }
    }

    guard explicitDay || hour != nil else { return nil }
    let base = dayBase ?? now
    let finalHour = hour ?? Moment.morning
    guard var date = at(hour: finalHour, minute: minute, on: base, calendar: calendar) else { return nil }

    // Une heure sans jour, ou un jour de semaine qui tombe aujourd'hui, déjà
    // passé → on glisse au lendemain (ou à la semaine suivante).
    if date <= now {
      if !explicitDay || calendar.isDate(base, inSameDayAs: now) {
        if let weekdayToken = tokens.first(where: { weekday($0) != nil }), let wd = weekday(weekdayToken) {
          let next = nextWeekday(wd, from: day(1, from: now, calendar: calendar), calendar: calendar, allowToday: true)
          guard let shifted = at(hour: finalHour, minute: minute, on: next, calendar: calendar) else { return nil }
          date = shifted
        } else {
          guard let shifted = at(hour: finalHour, minute: minute, on: day(1, from: now, calendar: calendar), calendar: calendar) else { return nil }
          date = shifted
        }
      }
    }
    return date > now ? date : nil
  }

  // MARK: - Libellé

  /// « Aujourd'hui à 18:00 », « Demain à 9:00 », « Lundi à 9:00 », « 12 sept. à 9:00 ».
  public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = timeString(date, calendar: calendar)
    if calendar.isDate(date, inSameDayAs: now) { return "Aujourd’hui à \(time)" }
    if calendar.isDate(date, inSameDayAs: day(1, from: now, calendar: calendar)) { return "Demain à \(time)" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
    if (0..<7).contains(days) {
      let weekday = calendar.component(.weekday, from: date)
      return "\(weekdayNames[weekday - 1].capitalized) à \(time)"
    }
    let comps = calendar.dateComponents([.day, .month, .year], from: date)
    let month = monthShort[(comps.month ?? 1) - 1]
    let sameYear = calendar.component(.year, from: now) == comps.year
    let dayPart = "\(comps.day ?? 1) \(month)" + (sameYear ? "" : " \(comps.year ?? 0)")
    return "\(dayPart) à \(time)"
  }

  public static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
    let comps = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", comps.hour ?? 0, comps.minute ?? 0)
  }

  // MARK: - Privé

  private static let weekdayNames = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
  private static let monthNames = [
    "janvier", "fevrier", "mars", "avril", "mai", "juin",
    "juillet", "aout", "septembre", "octobre", "novembre", "decembre",
  ]
  private static let monthShort = [
    "janv.", "févr.", "mars", "avr.", "mai", "juin",
    "juil.", "août", "sept.", "oct.", "nov.", "déc.",
  ]

  /// Minuscules, sans accents, ponctuation apaisée — « Lundi 9h » ≡ « lundi 9h ».
  private static func fold(_ input: String) -> String {
    let folded = input
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
      .lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: ",", with: " ")
    return folded.split(separator: " ").joined(separator: " ")
  }

  /// « 14h », « 14h30 », « 14:30 », « 9h05 ».
  private static func clockTime(_ token: String) -> (Int, Int)? {
    let separators: [Character] = ["h", ":"]
    for sep in separators {
      guard let range = token.firstIndex(of: sep) else { continue }
      let hourPart = token[token.startIndex..<range]
      let minutePart = token[token.index(after: range)...]
      guard let hour = Int(hourPart), (0...23).contains(hour) else { return nil }
      if minutePart.isEmpty { return (hour, 0) }
      guard let minute = Int(minutePart), (0...59).contains(minute) else { return nil }
      return (hour, minute)
    }
    return nil
  }

  private static func momentHour(_ token: String) -> Int? {
    switch token {
    case "matin", "matinee": Moment.morning
    case "midi": Moment.noon
    case "apres-midi", "apresmidi", "aprem": Moment.afternoon
    case "soir", "soiree": Moment.evening
    default: nil
    }
  }

  /// Numéro `Calendar.weekday` (1 = dimanche) d'un nom de jour français.
  private static func weekday(_ token: String) -> Int? {
    guard let index = weekdayNames.firstIndex(of: token) else { return nil }
    return index + 1
  }

  private static func number(_ token: String) -> Int? {
    switch token {
    case "un", "une": 1
    case "deux": 2
    case "trois": 3
    case "quatre": 4
    case "cinq": 5
    case "six": 6
    case "sept": 7
    case "huit": 8
    case "neuf": 9
    case "dix": 10
    case "quinze": 15
    case "vingt": 20
    case "trente": 30
    default: Int(token)
    }
  }

  /// « 2 h », « 2h », « 30 min », « 3 jours », « une semaine », « 2 mois ».
  private static func relative(_ tokens: [String], now: Date, calendar: Calendar) -> Date? {
    guard let first = tokens.first else { return nil }
    var amount: Int
    var unit: String
    if let n = number(first) {
      amount = n
      guard tokens.count >= 2 else { return nil }
      unit = tokens[1]
    } else if let split = splitNumberUnit(first) {
      amount = split.0
      unit = split.1
    } else {
      return nil
    }
    guard amount > 0 else { return nil }
    let component: Calendar.Component
    switch unit {
    case "min", "mn", "minute", "minutes": component = .minute
    case "h", "heure", "heures": component = .hour
    case "j", "jour", "jours": component = .day
    case "sem", "semaine", "semaines": component = .weekOfYear
    case "mois": component = .month
    default: return nil
    }
    // « dans 3 jours » sans heure : on garde l'heure courante, comme Beeper.
    let date = calendar.date(byAdding: component, value: amount, to: now)
    return date.flatMap { $0 > now ? $0 : nil }
  }

  /// « 2h » ou « 30min » collés.
  private static func splitNumberUnit(_ token: String) -> (Int, String)? {
    let digits = token.prefix { $0.isNumber }
    guard !digits.isEmpty, let n = Int(digits) else { return nil }
    let rest = String(token.dropFirst(digits.count))
    guard !rest.isEmpty else { return nil }
    return (n, rest)
  }

  /// « 12 septembre », « 12/09 », « 12/09/2027 ». Avance `index` sur les mots consommés.
  private static func calendarDay(_ tokens: [String], at index: inout Int, now: Date, calendar: Calendar) -> Date? {
    // « 1er janvier » : l'ordinal se lit comme le nombre.
    let token = tokens[index].hasSuffix("er") ? String(tokens[index].dropLast(2)) : tokens[index]
    let year = calendar.component(.year, from: now)
    if token.contains("/") {
      let parts = token.split(separator: "/").map(String.init)
      guard parts.count >= 2, let d = Int(parts[0]), let m = Int(parts[1]) else { return nil }
      let y = parts.count > 2 ? Int(parts[2]).map { $0 < 100 ? $0 + 2000 : $0 } : nil
      return resolveDay(day: d, month: m, year: y, now: now, calendar: calendar)
    }
    guard let d = Int(token), (1...31).contains(d), index + 1 < tokens.count,
          let m = monthNames.firstIndex(of: tokens[index + 1])
    else { return nil }
    index += 1
    var y: Int? = nil
    if index + 1 < tokens.count, let candidate = Int(tokens[index + 1]), candidate >= year {
      y = candidate
      index += 1
    }
    return resolveDay(day: d, month: m + 1, year: y, now: now, calendar: calendar)
  }

  /// Sans année : la prochaine occurrence (l'an prochain si la date est passée).
  private static func resolveDay(day: Int, month: Int, year: Int?, now: Date, calendar: Calendar) -> Date? {
    var comps = DateComponents()
    comps.day = day
    comps.month = month
    comps.year = year ?? calendar.component(.year, from: now)
    guard let date = calendar.date(from: comps) else { return nil }
    if year == nil, calendar.startOfDay(for: date) < calendar.startOfDay(for: now) {
      comps.year! += 1
      return calendar.date(from: comps)
    }
    return date
  }

  private static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: offset, to: date) ?? date
  }

  private static func nextWeekday(_ weekday: Int, from date: Date, calendar: Calendar, allowToday: Bool) -> Date {
    let current = calendar.component(.weekday, from: date)
    var delta = (weekday - current + 7) % 7
    if delta == 0, !allowToday { delta = 7 }
    return day(delta, from: date, calendar: calendar)
  }

  private static func at(hour: Int, minute: Int, on date: Date, calendar: Calendar) -> Date? {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
  }
}
