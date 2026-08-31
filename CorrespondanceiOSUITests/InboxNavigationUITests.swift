import XCTest

/// Le seul test d'interface de l'app : taper une ligne ouvre son fil, le
/// bouton retour ramène à la file.
///
/// Il existe pour une raison précise. En C1, la colonne de détail du
/// `NavigationSplitView` portait son propre `NavigationStack` : la sélection
/// changeait bien, mais rien ne s'ouvrait — on tapait dans le vide. Aucun test
/// unitaire ne pouvait le voir, c'est une histoire de hiérarchie de vues. Il
/// tourne en mode démonstration (`-CorrespondanceDemo`) : ni Relais, ni réseau,
/// des conversations en dur venues des vraies fixtures `/sync`.
final class InboxNavigationUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testTappingAConversationOpensItsThreadAndBackReturnsToTheList() {
    let app = XCUIApplication()
    app.launchArguments = ["-CorrespondanceDemo"]
    app.launch()

    // La ligne, cherchée par son étiquette d'accessibilité — celle que
    // `ConversationRow` compose (« Alice, Signal, 2 non lus, brouillon : … »).
    let alice = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Alice,"))
      .firstMatch
    XCTAssertTrue(alice.waitForExistence(timeout: 20), "la file n'a pas affiché la ligne « Alice »")
    alice.tap()

    // Le menu « … » du fil : il n'existe nulle part ailleurs dans l'app.
    let threadMenu = app.buttons["Actions de la conversation"]
    XCTAssertTrue(threadMenu.waitForExistence(timeout: 10), "taper la ligne n'a pas ouvert le fil")

    // Retour : le premier bouton de la barre de navigation, quel que soit son
    // libellé — la langue du simulateur n'est pas de notre ressort.
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5), "le fil n'a pas de bouton retour")
    back.tap()

    XCTAssertTrue(
      alice.waitForExistence(timeout: 10),
      "le retour n'a pas ramené à la file"
    )
    XCTAssertFalse(threadMenu.exists, "le fil est resté ouvert après le retour")
  }
}
