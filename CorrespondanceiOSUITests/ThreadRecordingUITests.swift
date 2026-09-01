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
