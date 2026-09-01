import XCTest

/// Maintenir le micro pour parler : le geste, et le rappel qui suit le doigt.
/// Le simulateur n'a pas de micro — ce qu'on vérifie ici, c'est que le geste
/// existe et que rien ne casse quand l'enregistrement ne démarre pas.
final class ThreadRecordingUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testMaintenirLeMicroNeCasseRien() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo", "-CorrespondanceDemoScreen", "fil"]
    app.launch()
    let mic = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Enregistrer un message vocal"))
      .firstMatch
    XCTAssertTrue(mic.waitForExistence(timeout: 20), "pas de micro dans le composer")

    let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let png = XCTestExpectation(description: "capture pendant le maintien")
    var data: Data?
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.4) {
      data = XCUIScreen.main.screenshot().pngRepresentation
      png.fulfill()
    }
    // Un maintien, et un glissement vers la gauche qui reste EN DEÇÀ du seuil :
    // le rappel doit paraître sans que le message soit abandonné.
    start.press(
      forDuration: 0.6,
      thenDragTo: start.withOffset(CGVector(dx: -40, dy: 0)),
      withVelocity: .slow,
      thenHoldForDuration: 1.6
    )
    wait(for: [png], timeout: 10)
    joindre(data, nom: "07-maintien")
    // Le fil est toujours là : un geste avorté ne vide pas la conversation.
    XCTAssertTrue(app.buttons["Actions de la conversation"].exists, "le fil a disparu après le geste")
  }

  /// Glisser vers le haut pose le doigt : la bulle garde l'enregistrement,
  /// avec son « Annuler » et sa flèche d'envoi.
  func testGlisserVersLeHautVerrouille() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo", "-CorrespondanceDemoScreen", "fil"]
    app.launch()
    let mic = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Enregistrer un message vocal"))
      .firstMatch
    XCTAssertTrue(mic.waitForExistence(timeout: 20), "pas de micro dans le composer")

    let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.6,
      thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)),
      withVelocity: .slow,
      thenHoldForDuration: 1.2
    )
    // Le doigt est reparti : la bulle garde l'enregistrement.
    joindre(XCUIScreen.main.screenshot().pngRepresentation, nom: "08-verrouille")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "Annuler le message vocal"))
        .firstMatch.waitForExistence(timeout: 2),
      "le verrou n'a pas gardé l'enregistrement"
    )
    XCTAssertTrue(app.buttons["Actions de la conversation"].exists, "le fil a disparu après le verrou")
  }

  /// La pilule ↓ et le guide du verrou visent le même coin : tant que le doigt
  /// tient le micro, la pilule s'efface — sinon deux pastilles se recouvrent.
  func testLaPiluleSEfaceQuandOnTientLeMicro() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()

    let group = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vacances 2026,"))
      .firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 20), "la file n'a pas affiché « Vacances 2026 »")
    group.tap()

    // Remonter d'abord : la pilule est là, et c'est elle qui doit disparaître.
    let chevron = app.buttons["Aller au dernier message"]
    app.swipeDown()
    app.swipeDown()
    XCTAssertTrue(chevron.waitForExistence(timeout: 5), "le chevron n'est pas apparu en remontant")

    let mic = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Enregistrer un message vocal"))
      .firstMatch
    XCTAssertTrue(mic.waitForExistence(timeout: 5), "pas de micro dans le composer")

    let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let pendantLeMaintien = XCTestExpectation(description: "regarder pendant le maintien")
    var piluleVisible = true
    var data: Data?
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.4) {
      piluleVisible = chevron.exists
      data = XCUIScreen.main.screenshot().pngRepresentation
      pendantLeMaintien.fulfill()
    }
    start.press(
      forDuration: 0.6,
      thenDragTo: start.withOffset(CGVector(dx: 0, dy: -20)),
      withVelocity: .slow,
      thenHoldForDuration: 1.6
    )
    wait(for: [pendantLeMaintien], timeout: 10)
    joindre(data, nom: "10-maintien-sans-pilule")
    XCTAssertFalse(piluleVisible, "la pilule ↓ est restée sous le guide du verrou")
  }

  /// Les captures partent dans le rapport, et sur le disque quand on le demande.
  private func joindre(_ data: Data?, nom: String) {
    guard let data else { return }
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(nom).png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: nom, payload: data)
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
