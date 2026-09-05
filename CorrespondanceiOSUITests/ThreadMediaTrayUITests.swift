import XCTest

/// Le « + » du composer ouvre le plateau de la pellicule à la place du
/// clavier ; la croix rend le clavier ; le « + » le remplace à nouveau. Un
/// geste, un état : rien qu'un test unitaire voie.
final class ThreadMediaTrayUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testPlusSwapsTrayAndKeyboard() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()

    let alice = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Alice,"))
      .firstMatch
    XCTAssertTrue(alice.waitForExistence(timeout: 20), "la file n'a pas affiché « Alice »")
    alice.tap()
    let threadMenu = app.buttons["Actions de la conversation"]
    if !threadMenu.waitForExistence(timeout: 10) { alice.tap() }
    XCTAssertTrue(threadMenu.waitForExistence(timeout: 10), "taper la ligne n'a pas ouvert le fil")

    // Par identifiant : son étiquette change avec l'état.
    let plus = app.buttons["composer.plus"]
    XCTAssertTrue(plus.waitForExistence(timeout: 10), "le composer n'a pas de « + »")
    plus.tap()

    let camera = app.buttons["Caméra"]
    XCTAssertTrue(camera.waitForExistence(timeout: 10), "le « + » n'a pas ouvert le plateau")
    let plusFrame = plus.frame

    // La croix rend le clavier : le plateau s'efface sous lui, et le « + »
    // n'a pas bougé d'un point.
    XCTAssertEqual(plus.label, "Fermer le plateau des médias")
    plus.tap()
    XCTAssertTrue(camera.waitForNonExistence(timeout: 5), "la croix n'a pas refermé le plateau")
    if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = "sans-clavier"
      shot.lifetime = .keepAlways
      add(shot)
      XCTFail("la croix n'a pas rendu le clavier")
    }
    XCTAssertEqual(plus.frame.minY, plusFrame.minY, accuracy: 2, "le composer a bougé en passant au clavier")

    // Le « + » remplace le clavier par le plateau, toujours sans bouger.
    plus.tap()
    XCTAssertTrue(camera.waitForExistence(timeout: 5), "le « + » n'a pas remplacé le clavier par le plateau")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "le clavier est resté")
    XCTAssertEqual(plus.frame.minY, plusFrame.minY, accuracy: 2, "le composer a bougé en revenant au plateau")

    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "plateau"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
