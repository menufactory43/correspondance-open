import XCTest

/// Les gestes du fil, en mode démonstration : la pilule ouvre la fiche, le
/// balayage cite sans recouvrir l'écran, l'appui long montre les smileys et
/// les actions. Trois choses qu'aucun test unitaire ne voit — ce sont des
/// gestes, et un encart qui déborde.
final class ThreadGesturesUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func openGroup(_ app: XCUIApplication) {
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()
    let group = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vacances 2026,"))
      .firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 20), "la file n'a pas affiché « Vacances 2026 »")
    group.tap()
    XCTAssertTrue(app.buttons["Actions de la conversation"].waitForExistence(timeout: 10))
  }

  private func snapshot(_ app: XCUIApplication, _ name: String) {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testPillOpensThreadInfo() {
    let app = XCUIApplication()
    openGroup(app)
    snapshot(app, "01-fil")

    let pill = app.navigationBars.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vacances 2026"))
      .firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 5), "la pilule n'est pas dans la barre")
    pill.tap()

    XCTAssertTrue(app.staticTexts["Rechercher"].waitForExistence(timeout: 5), "la fiche ne s'est pas ouverte")
    XCTAssertTrue(app.staticTexts["Membres"].exists)
    snapshot(app, "02-fiche")
  }

  func testSwipeQuotesWithoutCoveringTheThread() {
    let app = XCUIApplication()
    openGroup(app)

    // Une bulle reçue, au milieu du fil : la dernière parole de « Reçu ».
    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reçu,"))
      .allElementsBoundByIndex
      .last
    XCTAssertNotNil(bubble, "aucune bulle reçue dans le fil")
    bubble!.swipeRight()

    let cancel = app.buttons["Ne plus citer ce message"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "le balayage n'a pas cité le message")
    snapshot(app, "03-citation")

    // L'encart doit coiffer le champ, pas manger l'écran : le bouton pour
    // annuler la citation reste dans le tiers bas, et le menu du haut visible.
    let frame = cancel.frame
    XCTAssertGreaterThan(frame.minY, app.frame.height * 0.5, "la citation a envahi l'écran")
    XCTAssertTrue(app.buttons["Actions de la conversation"].isHittable)
  }

  func testLongPressShowsReactionsAndActions() {
    let app = XCUIApplication()
    openGroup(app)

    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reçu,"))
      .allElementsBoundByIndex
      .last
    XCTAssertNotNil(bubble)
    bubble!.press(forDuration: 0.6)

    XCTAssertTrue(app.buttons["Réagir 👍"].waitForExistence(timeout: 5), "pas de rangée de smileys")
    XCTAssertTrue(app.buttons["Un autre emoji"].exists)
    XCTAssertTrue(app.buttons["Répondre en citant"].exists)
    XCTAssertTrue(app.buttons["Copier le texte"].exists)
    snapshot(app, "04-appui-long")

    app.buttons["Réagir 👍"].tap()
    XCTAssertTrue(app.buttons["Réagir 👍"].waitForNonExistence(timeout: 5), "l'overlay ne s'est pas refermé")
  }
}
