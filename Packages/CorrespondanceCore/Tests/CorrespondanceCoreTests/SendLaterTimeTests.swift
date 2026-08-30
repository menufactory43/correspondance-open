import XCTest
@testable import CorrespondanceCore

/// « Quand ? » en français : ce qu'on comprend, et ce qu'on refuse.
final class SendLaterTimeTests: XCTestCase {
  private var calendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Paris")!
    cal.firstWeekday = 2
    return cal
  }

  /// Mercredi 2 septembre 2026, 15:30.
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 15, minute: 30))!
  }

  private func date(_ day: Int, _ month: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func parse(_ input: String) -> Date? {
    SendLaterTime.parse(input, now: now, calendar: calendar)
  }

  func testRelativeDurations() {
    XCTAssertEqual(parse("dans 2h"), now.addingTimeInterval(7_200))
    XCTAssertEqual(parse("dans 2 heures"), now.addingTimeInterval(7_200))
    XCTAssertEqual(parse("dans une heure"), now.addingTimeInterval(3_600))
    XCTAssertEqual(parse("dans 30 min"), now.addingTimeInterval(1_800))
    XCTAssertEqual(parse("dans 3 jours"), date(5, 9, 15, 30))
    XCTAssertEqual(parse("dans une semaine"), date(9, 9, 15, 30))
  }

  func testTomorrowAndMoments() {
    XCTAssertEqual(parse("demain"), date(3, 9, 9))
    XCTAssertEqual(parse("Demain matin"), date(3, 9, 9))
    XCTAssertEqual(parse("demain soir"), date(3, 9, 18))
    XCTAssertEqual(parse("demain à 14h30"), date(3, 9, 14, 30))
    XCTAssertEqual(parse("demain 8:15"), date(3, 9, 8, 15))
    XCTAssertEqual(parse("ce soir"), date(2, 9, 18))
    XCTAssertEqual(parse("après-demain midi"), date(4, 9, 12))
  }

  /// Une heure seule vaut pour aujourd'hui, ou demain si elle est déjà passée.
  func testBareTimeRollsToTomorrowWhenPast() {
    XCTAssertEqual(parse("18h"), date(2, 9, 18))
    XCTAssertEqual(parse("9h"), date(3, 9, 9))
    XCTAssertEqual(parse("matin"), date(3, 9, 9))
  }

  func testWeekdays() {
    // Mercredi → vendredi de la même semaine, lundi de la suivante.
    XCTAssertEqual(parse("vendredi"), date(4, 9, 9))
    XCTAssertEqual(parse("lundi matin"), date(7, 9, 9))
    XCTAssertEqual(parse("Lundi 10h"), date(7, 9, 10))
    // Aujourd'hui, mercredi : l'heure encore à venir reste aujourd'hui, sinon la semaine prochaine.
    XCTAssertEqual(parse("mercredi 18h"), date(2, 9, 18))
    XCTAssertEqual(parse("mercredi 9h"), date(9, 9, 9))
    XCTAssertEqual(parse("ce week-end"), date(5, 9, 10))
    XCTAssertEqual(parse("la semaine prochaine"), date(7, 9, 9))
  }

  func testCalendarDays() {
    XCTAssertEqual(parse("12 septembre"), date(12, 9, 9))
    XCTAssertEqual(parse("12 septembre 18h"), date(12, 9, 18))
    XCTAssertEqual(parse("12/09"), date(12, 9, 9))
    // Date passée sans année → l'an prochain.
    XCTAssertEqual(parse("1er janvier"), date(1, 1, 9, year: 2027))
    XCTAssertEqual(parse("1 janvier 2027"), date(1, 1, 9, year: 2027))
  }

  func testRejectsNonsenseAndPast() {
    XCTAssertNil(parse(""))
    XCTAssertNil(parse("bonjour"))
    XCTAssertNil(parse("dans 0 min"))
    XCTAssertNil(parse("dans trois"))
    XCTAssertNil(parse("25h"))
  }

  func testSuggestionsSkipThePast() {
    let titles = SendLaterTime.suggestions(now: now, calendar: calendar).map(\.title)
    XCTAssertEqual(titles, ["Dans une heure", "Dans deux heures", "Ce soir", "Demain matin", "Ce week-end", "Lundi matin"])

    let lateEvening = date(2, 9, 22)
    let late = SendLaterTime.suggestions(now: lateEvening, calendar: calendar).map(\.title)
    XCTAssertFalse(late.contains("Ce soir"))
    XCTAssertTrue(late.contains("Demain matin"))
  }

  func testLabels() {
    XCTAssertEqual(SendLaterTime.label(for: date(2, 9, 18), now: now, calendar: calendar), "Aujourd’hui à 18:00")
    XCTAssertEqual(SendLaterTime.label(for: date(3, 9, 9, 5), now: now, calendar: calendar), "Demain à 9:05")
    XCTAssertEqual(SendLaterTime.label(for: date(7, 9, 9), now: now, calendar: calendar), "Lundi à 9:00")
    XCTAssertEqual(SendLaterTime.label(for: date(12, 9, 9), now: now, calendar: calendar), "12 sept. à 9:00")
    XCTAssertEqual(SendLaterTime.label(for: date(1, 1, 9, year: 2027), now: now, calendar: calendar), "1 janv. 2027 à 9:00")
  }

  func testScheduledMessageDisplayTextAndDue() {
    let photo = ScheduledMessage(conversationID: "c", text: "  ", attachmentPaths: ["/tmp/x.jpg"], sendAt: now)
    XCTAssertEqual(photo.displayText, "📷 Photo")
    XCTAssertTrue(photo.isDue(at: now))
    XCTAssertFalse(photo.isDue(at: now.addingTimeInterval(-1)))
  }
}
