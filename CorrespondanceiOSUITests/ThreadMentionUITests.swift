import XCTest

/// La rangée « @ » du composer, en mode démonstration : taper « @cl » dans un
/// groupe fait paraître les gens qui répondent au préfixe, et une tape pose
/// « @Clara Nguyen » dans le brouillon. Un doigt et un clavier : rien qu'un
/// test unitaire ne voit.
final class ThreadMentionUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testTypingAtSignOffersGroupMembers() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo", "-CorrespondanceDemoScreen", "fil"]
    app.launch()
    XCTAssertTrue(app.buttons["Actions de la conversation"].waitForExistence(timeout: 20))

    let field = app.textViews.firstMatch.exists
      ? app.textViews.firstMatch
      : app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10), "le champ du composer est introuvable")
    field.tap()
    field.typeText("@cl")

    let candidate = app.buttons["Mentionner Clara Nguyen"]
    XCTAssertTrue(candidate.waitForExistence(timeout: 5), "la rangée de mentions n'est pas apparue")

    let png = XCUIScreen.main.screenshot().pngRepresentation
    if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("10-mentions.png"))
    }
    let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "10-mentions", payload: png)
    attachment.lifetime = .keepAlways
    add(attachment)

    // La tape pose « @Nom » dans le brouillon, comme le menu du Mac.
    candidate.tap()
    XCTAssertTrue(
      app.staticTexts["@Clara Nguyen"].waitForExistence(timeout: 5)
        || (field.value as? String)?.contains("@Clara Nguyen") == true,
      "la mention n'est pas arrivée dans le brouillon"
    )
    XCTAssertTrue(candidate.waitForNonExistence(timeout: 5), "la rangée est restée après le choix")
  }
}
