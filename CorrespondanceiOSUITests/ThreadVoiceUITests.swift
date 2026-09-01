import XCTest

/// Le vocal à l'écoute : la pastille d'allure tourne, l'onde est un curseur.
/// Deux choses qu'aucun test unitaire ne voit — ce sont des gestes.
final class ThreadVoiceUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  private func openAlice(_ app: XCUIApplication) {
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Alice"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20), "la file n'a pas affiché la conversation d'Alice")
    row.tap()
  }

  private func snapshot(_ name: String) {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func speedPill(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vitesse d'écoute"))
      .firstMatch
  }

  func testLaPastilleDAllureTourneJusquADeuxFois() {
    let app = XCUIApplication()
    openAlice(app)
    XCTAssertTrue(speedPill(app).waitForExistence(timeout: 10), "pas de pastille de vitesse sous le vocal")
    // L'allure choisie survit d'une écoute à l'autre : on part de celle qui est
    // là, et on vérifie que trois tapes font le tour complet.
    var seen: [String] = []
    for _ in 0..<4 {
      seen.append(speedPill(app).label)
      speedPill(app).tap()
    }
    for allure in ["1×", "1,5×", "2×"] {
      XCTAssertTrue(seen.contains { $0.contains(allure) }, "l'allure \(allure) manque au tour")
    }
    XCTAssertEqual(seen[0], seen[3], "le tour ne revient pas à son point de départ")
    while !speedPill(app).label.contains("2×") { speedPill(app).tap() }
    snapshot("06-vocal-2x")
  }

  /// L'onde est un curseur : on y pose le doigt et la position suit.
  func testGlisserSurLOndeDeplaceLaPosition() {
    let app = XCUIApplication()
    openAlice(app)
    let wave = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Position dans le message"))
      .firstMatch
    XCTAssertTrue(wave.waitForExistence(timeout: 10), "l'onde n'est pas un curseur")
    let before = wave.value as? String
    wave.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
      .press(forDuration: 0.1, thenDragTo: wave.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    XCTAssertNotEqual(wave.value as? String, before, "le glissement n'a pas déplacé la lecture")
  }
}
