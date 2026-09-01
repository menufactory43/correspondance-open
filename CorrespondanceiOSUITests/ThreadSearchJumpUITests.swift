import XCTest

/// Chercher dans un fil et TOMBER sur le message : la feuille se referme, le
/// fil s'y rend, la bulle s'éclaire. Avant, on revenait au bas du fil.
final class ThreadSearchJumpUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testUnResultatMeneAuMessage() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo", "-CorrespondanceDemoScreen", "fil"]
    app.launch()
    XCTAssertTrue(app.buttons["Actions de la conversation"].waitForExistence(timeout: 20))

    let pill = app.navigationBars.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Vacances 2026"))
      .firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    pill.tap()

    let search = app.buttons["Rechercher"].firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10), "la fiche n'offre pas la recherche")
    search.tap()

    let field = app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("Crozon")

    let hit = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Crozon c'est magnifique"))
      .firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 10), "la recherche n'a rien trouvé")
    hit.tap()
    // La capture pendant que l'éclat dure : il ne tient qu'une seconde.
    Thread.sleep(forTimeInterval: 0.9)
    snapshot()

    // Le message visé est à l'écran, dans le fil — pas derrière une feuille.
    let bubble = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Crozon c'est magnifique"))
      .firstMatch
    XCTAssertTrue(bubble.waitForExistence(timeout: 10), "le fil n'a pas rejoint le message")
    XCTAssertTrue(app.buttons["Actions de la conversation"].waitForExistence(timeout: 10), "on n'est pas revenu au fil")

  }

  private func snapshot() {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("08-recherche-saut.png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "08-recherche-saut", payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
