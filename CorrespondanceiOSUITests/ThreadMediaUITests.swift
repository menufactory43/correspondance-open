import XCTest

/// La mosaïque d'un message à plusieurs photos, et la visionneuse qu'elle
/// ouvre : deux choses qui ne se voient qu'au doigt.
final class ThreadMediaUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testTappingAlbumTileOpensViewer() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()

    let thread = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Atelier photo,"))
      .firstMatch
    XCTAssertTrue(thread.waitForExistence(timeout: 20), "la file n'a pas affiché « Atelier photo »")
    thread.tap()

    let tile = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo 1 sur 4"))
      .firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "la mosaïque n'a pas montré sa première tuile")
    tile.tap()

    let close = app.buttons["Fermer"]
    XCTAssertTrue(close.waitForExistence(timeout: 10), "la visionneuse ne s'est pas ouverte")

    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "visionneuse"
    attachment.lifetime = .keepAlways
    add(attachment)

    close.tap()
    XCTAssertTrue(close.waitForNonExistence(timeout: 5), "la visionneuse ne s'est pas refermée")
  }
}
