import XCTest

@testable import Correspondance

/// Une fenêtre ne s'ouvre jamais plus grande que son écran, ni hors de ses
/// limites — quoi que raconte le cadre enregistré.
///
/// Le cas qui a motivé tout ça, relevé sur un profil neuf :
/// `"NSWindow Frame inbox-AppWindow-1" = "0 -1273 1440 2142 0 0 1440 869"`.
/// 2142 pixels de haut sur un écran de 869, posée à `y = -1273` : le champ de
/// saisie était hors de l'écran, on ne pouvait pas envoyer de message.
final class WindowFrameGuardTests: XCTestCase {
  /// L'écran de la machine d'essai, `visibleFrame` (barre de menus déduite).
  let ecran = CGRect(x: 0, y: 0, width: 1440, height: 869)
  let minimum = CGSize(width: 720, height: 480)

  func testLeCadreRelevéSurUnProfilNeufRentreDansLEcran() {
    let absurde = CGRect(x: 0, y: -1273, width: 1440, height: 2142)
    let borne = WindowFrameGuard.clamp(absurde, visible: ecran, minimum: minimum)

    XCTAssertLessThanOrEqual(borne.height, ecran.height, "jamais plus haut que l'écran")
    XCTAssertLessThanOrEqual(borne.width, ecran.width)
    XCTAssertGreaterThanOrEqual(borne.minY, ecran.minY, "et jamais sous le bord bas")
    XCTAssertLessThanOrEqual(borne.maxY, ecran.maxY, "ni au-dessus du bord haut")
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: ecran))
  }

  func testUneFenetreSaineNEstPasTouchee() {
    let sain = CGRect(x: 100, y: 60, width: 1100, height: 760)
    XCTAssertTrue(WindowFrameGuard.fits(sain, visible: ecran))
    XCTAssertEqual(WindowFrameGuard.clamp(sain, visible: ecran, minimum: minimum), sain)
  }

  /// Un profil migré depuis un écran plus grand : le cadre enregistré parle
  /// d'un moniteur qui n'est plus là.
  func testUnCadreVenuDUnPlusGrandEcranEstRamene() {
    let grandEcran = CGRect(x: 0, y: 0, width: 2560, height: 1400)
    let borne = WindowFrameGuard.clamp(grandEcran, visible: ecran, minimum: minimum)
    XCTAssertEqual(borne.width, 1440)
    XCTAssertEqual(borne.height, 869)
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: ecran))
  }

  func testUneFenetreQuiDebordeAGaucheEstRamenee() {
    let dehors = CGRect(x: -800, y: 100, width: 1100, height: 700)
    let borne = WindowFrameGuard.clamp(dehors, visible: ecran, minimum: minimum)
    XCTAssertEqual(borne.minX, 0)
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: ecran))
  }

  func testUneFenetreQuiDebordeADroiteEstRamenee() {
    let dehors = CGRect(x: 1300, y: 100, width: 1100, height: 700)
    let borne = WindowFrameGuard.clamp(dehors, visible: ecran, minimum: minimum)
    XCTAssertEqual(borne.maxX, ecran.maxX)
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: ecran))
  }

  func testLeMinimumEstRespecte() {
    let minuscule = CGRect(x: 10, y: 10, width: 200, height: 120)
    let borne = WindowFrameGuard.clamp(minuscule, visible: ecran, minimum: minimum)
    XCTAssertEqual(borne.width, minimum.width)
    XCTAssertEqual(borne.height, minimum.height)
  }

  /// Sur un écran plus petit que le minimum souhaité, c'est l'écran qui gagne :
  /// sinon on repousserait la fenêtre hors de ses bords pour rien.
  func testUnPetitEcranGagneSurLeMinimum() {
    let petit = CGRect(x: 0, y: 0, width: 640, height: 400)
    let borne = WindowFrameGuard.clamp(
      CGRect(x: 0, y: 0, width: 1100, height: 760), visible: petit, minimum: minimum
    )
    XCTAssertEqual(borne.width, 640)
    XCTAssertEqual(borne.height, 400)
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: petit))
  }

  /// Un écran secondaire ne commence pas à l'origine : la borne doit suivre.
  func testUnEcranSecondaireEstPrisEnCompte() {
    let secondaire = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
    let borne = WindowFrameGuard.clamp(
      CGRect(x: 0, y: 0, width: 3000, height: 2000), visible: secondaire, minimum: minimum
    )
    XCTAssertEqual(borne.minX, 1440)
    XCTAssertEqual(borne.minY, 200)
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: secondaire))
  }

  func testUneFenetreDetachéeMinusculeResteUtilisable() {
    // Le post-it : 240 × 180, et il doit pouvoir rester si petit.
    let postIt = CGRect(x: 20, y: 20, width: 240, height: 180)
    let borne = WindowFrameGuard.clamp(
      postIt, visible: ecran, minimum: CGSize(width: 240, height: 180)
    )
    XCTAssertEqual(borne.size, postIt.size)
  }
}
