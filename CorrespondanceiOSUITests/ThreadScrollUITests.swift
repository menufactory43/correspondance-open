import XCTest

/// Où le fil se pose en s'ouvrant, et ce que le chevron en dit. Un défilement
/// programmé et un geste — rien qu'un test unitaire ne voie.
final class ThreadScrollUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func openThread(_ app: XCUIApplication, named name: String) {
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20), "la file n'a pas affiché « \(name) »")
    row.tap()
    XCTAssertTrue(
      app.buttons["Actions de la conversation"].waitForExistence(timeout: 10),
      "taper la ligne n'a pas ouvert le fil")
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

  /// Un fil SANS rien à lire s'ouvre sur sa dernière bulle, sans qu'un doigt
  /// ait à la réveiller. C'est ce que la pile paresseuse ratait : elle estimait
  /// les rangées qu'elle n'avait pas mesurées et garait le fil au-delà de son
  /// propre bas — écran vide.
  func testAReadThreadOpensOnItsLastBubble() {
    let app = XCUIApplication()
    openThread(app, named: "Vacances 2026")

    let last = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Parfait, je note tout dans le carnet."))
      .firstMatch
    XCTAssertTrue(last.waitForExistence(timeout: 20), "la dernière bulle n'existe pas")
    XCTAssertTrue(last.isHittable, "la dernière bulle est dans l'arbre mais pas à l'écran")
    snapshot("09-fil-ouvert")
  }

  /// Un fil qui a des messages en attente s'ouvre sur LA BARRE, pas sur sa
  /// dernière bulle : ce qu'on vient d'ouvrir se lit sans avoir à remonter.
  /// Le chevron dit alors ce qui attend dessous.
  func testAnUnreadThreadOpensOnTheUnreadMark() {
    let app = XCUIApplication()
    openThread(app, named: "Copro · Rue des Lilas")

    let mark = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "messages non lus"))
      .firstMatch
    XCTAssertTrue(mark.waitForExistence(timeout: 20), "la barre des non-lus ne s'est pas posée")
    XCTAssertTrue(mark.isHittable, "la barre est dans l'arbre mais pas à l'écran")

    // Le bas n'est pas atteint : le chevron est là, et il mène au dernier
    // message — où il n'a plus rien à faire.
    let chevron = app.buttons["Aller au dernier message"]
    XCTAssertTrue(chevron.waitForExistence(timeout: 5), "le chevron n'annonce pas ce qui attend")
    snapshot("10-fil-non-lus")
    chevron.tap()
    XCTAssertTrue(
      chevron.waitForNonExistence(timeout: 5), "le chevron n'a pas ramené au dernier message")
  }

  func testChevronAppearsWhenScrolledUpAndReturnsToBottom() {
    let app = XCUIApplication()
    openThread(app, named: "Vacances 2026")

    // Remonter dans l'historique : le chevron doit se montrer.
    let chevron = app.buttons["Aller au dernier message"]
    app.swipeDown()
    app.swipeDown()
    XCTAssertTrue(chevron.waitForExistence(timeout: 5), "le chevron n'est pas apparu en remontant")
    snapshot("06-pilule")

    // Le taper ramène au bas du fil — où le chevron n'a plus rien à faire.
    chevron.tap()
    XCTAssertTrue(
      chevron.waitForNonExistence(timeout: 5), "le chevron n'a pas ramené au dernier message")
  }
}
