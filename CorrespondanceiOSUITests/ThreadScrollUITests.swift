import XCTest

/// Le chevron du fil, en mode démonstration : remonter dans l'historique le
/// fait apparaître au-dessus du composer, le taper ramène au dernier message.
/// Un geste et un défilement programmé — rien qu'un test unitaire ne voit.
final class ThreadScrollUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Le fil s'ouvre SUR sa dernière bulle, sans qu'un doigt ait à réveiller la
  /// pile paresseuse : elle estimait les rangées qu'elle n'avait pas mesurées
  /// et garait le fil au-delà de son propre bas — écran vide, cf.
  /// `defaultScrollAnchor(_:for: .sizeChanges)`.
  func testThreadOpensOnLastBubbleWithoutAnyGesture() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo", "-CorrespondanceDemoScreen", "fil"]
    app.launch()

    let last = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Parfait, je note tout dans le carnet."))
      .firstMatch
    XCTAssertTrue(last.waitForExistence(timeout: 20), "la dernière bulle n'existe pas")
    XCTAssertTrue(last.isHittable, "la dernière bulle est dans l'arbre mais pas à l'écran")

    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("09-fil-ouvert.png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "09-fil-ouvert", payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)
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

    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("06-pilule.png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "06-pilule", payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)

    // Le taper ramène au bas du fil — où le chevron n'a plus rien à faire.
    chevron.tap()
    XCTAssertTrue(chevron.waitForNonExistence(timeout: 5), "le chevron n'a pas ramené au dernier message")
  }
}
