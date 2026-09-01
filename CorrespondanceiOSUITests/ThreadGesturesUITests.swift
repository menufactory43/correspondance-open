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

    // La croix, dans la pilule du champ, retire la citation.
    cancel.tap()
    XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "la croix n'a pas retiré la citation")
  }

  /// La croix de la citation répond aussi le clavier levé : c'est là qu'on
  /// s'en sert, en plein message.
  func testQuoteCancelWorksWithKeyboardUp() {
    let app = XCUIApplication()
    openGroup(app)
    app.textFields.firstMatch.tap()

    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reçu,"))
      .allElementsBoundByIndex
      .last
    XCTAssertNotNil(bubble, "aucune bulle reçue dans le fil")
    bubble!.swipeRight()

    let cancel = app.buttons["Ne plus citer ce message"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "le balayage n'a pas cité le message")
    snapshot(app, "03b-citation-clavier")
    cancel.tap()
    XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "la croix n'a pas retiré la citation")
  }

  /// Le balayage EN COURS : la flèche paraît dans la marge libérée. La capture
  /// se prend pendant que le doigt tient, depuis une autre file — un geste
  /// terminé ne montre plus rien.
  func testSwipeShowsTheReplyGlyphWhileDragging() {
    let app = XCUIApplication()
    openGroup(app)

    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reçu,"))
      .allElementsBoundByIndex
      .last
    XCTAssertNotNil(bubble, "aucune bulle reçue dans le fil")
    let start = bubble!.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    let end = start.withOffset(CGVector(dx: 80, dy: 0))

    let taken = XCTestExpectation(description: "capture pendant le glissement")
    var png: Data?
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
      png = XCUIScreen.main.screenshot().pngRepresentation
      taken.fulfill()
    }
    start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2.5)
    wait(for: [taken], timeout: 10)

    let data = try? XCTUnwrap(png)
    XCTAssertNotNil(data, "aucune capture pendant le glissement")
    if let data {
      if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("05-balayage.png"))
      }
      let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "05-balayage", payload: data)
      attachment.lifetime = .keepAlways
      add(attachment)
    }
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

  /// « Sélectionner » ouvre le texte seul, avec les poignées du système :
  /// on peut n'en copier que quelques mots au lieu de la bulle entière.
  func testSelectOpensSelectableText() {
    let app = XCUIApplication()
    openGroup(app)

    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reçu,"))
      .allElementsBoundByIndex
      .last
    XCTAssertNotNil(bubble)
    bubble!.press(forDuration: 0.6)

    let select = app.buttons["Sélectionner"]
    XCTAssertTrue(select.waitForExistence(timeout: 5), "pas d'action « Sélectionner »")
    select.tap()

    let field = app.textViews["Texte à sélectionner"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), "la feuille de sélection ne s'est pas ouverte")
    XCTAssertFalse((field.value as? String ?? "").isEmpty, "le texte de la bulle n'est pas dans la feuille")
    XCTAssertTrue(app.buttons["Tout copier"].exists)
    snapshot(app, "05-selectionner")

    app.buttons["Fermer"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5), "la feuille ne s'est pas refermée")
  }
}
