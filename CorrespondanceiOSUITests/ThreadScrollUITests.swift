import XCTest

/// Le chevron du fil, en mode démonstration : remonter dans l'historique le
/// fait apparaître au-dessus du composer, le taper ramène au dernier message.
/// Un geste et un défilement programmé — rien qu'un test unitaire ne voit.
final class ThreadScrollUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testChevronAppearsWhenScrolledUpAndReturnsToBottom() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()

    let group = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vacances 2026,"))
      .firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 20), "la file n'a pas affiché « Vacances 2026 »")
    group.tap()
    XCTAssertTrue(app.buttons["Actions de la conversation"].waitForExistence(timeout: 10))

    // Remonter dans l'historique : le chevron doit se montrer.
    let chevron = app.buttons["Aller au dernier message"]
    app.swipeDown()
    app.swipeDown()
    XCTAssertTrue(chevron.waitForExistence(timeout: 5), "le chevron n'est pas apparu en remontant")

    // Le taper ramène au bas du fil — où le chevron n'a plus rien à faire.
    chevron.tap()
    XCTAssertTrue(chevron.waitForNonExistence(timeout: 5), "le chevron n'a pas ramené au dernier message")
  }
}
