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

  // MARK: - Le scénario réel : elle grandit APRÈS

  /// Une fenêtre de laboratoire. Créer une vraie `NSWindow` ici faisait planter
  /// le harnais injecté (exit 139) et emportait toute la suite en silence.
  @MainActor
  final class FenetreSimulee: WindowFrameTarget {
    var currentFrame: CGRect
    /// Ce que le contenu exige. La barre latérale, la liste et le fil ont
    /// chacun leur largeur minimale : leur somme peut dépasser l'écran.
    var currentContentMinSize: CGSize = .zero
    /// **Elle refuse ce qu'AppKit refuse.** La version précédente acceptait
    /// tout, et c'est exactement pour ça qu'elle n'a pas vu venir le `SIGABRT`
    /// au lancement : une fenêtre de laboratoire trop complaisante ne prouve
    /// rien du comportement qui compte.
    var currentContentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) {
      didSet {
        if currentContentMaxSize.width < currentContentMinSize.width
          || currentContentMaxSize.height < currentContentMinSize.height {
          aLeve = true
        }
      }
    }
    /// Vrai si on a posé un maximum sous le minimum — dans la vraie vie, l'app
    /// serait morte ici.
    private(set) var aLeve = false
    /// La barre de titre : le contenu est un peu plus court que le cadre.
    let hauteurTitre: CGFloat = 28
    private(set) var cadresPoses: [CGRect] = []

    init(frame: CGRect) {
      currentFrame = frame
    }

    func contentSize(forFrame frame: CGRect) -> CGSize {
      CGSize(width: frame.width, height: max(0, frame.height - hauteurTitre))
    }

    func applyFrame(_ frame: CGRect) {
      currentFrame = frame
      cadresPoses.append(frame)
    }
  }

  /// Le vrai défaut, celui qu'aucun test sur la fonction pure n'attrape : la
  /// fenêtre s'ouvre saine, **puis** SwiftUI la redimensionne sur la hauteur
  /// idéale du contenu quand les conversations arrivent.
  @MainActor
  func testUneFenetreQuiGranditApresLeMontageEstRamenee() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 869)
    let fenetre = FenetreSimulee(frame: CGRect(x: 100, y: 60, width: 1100, height: 760))
    let gardien = WindowFrameKeeper(
      target: fenetre, minimum: NSSize(width: 720, height: 480), visibleFrame: { visible }
    )

    gardien.apply()
    XCTAssertTrue(WindowFrameGuard.fits(fenetre.currentFrame, visible: visible), "saine au montage")
    XCTAssertTrue(fenetre.cadresPoses.isEmpty, "on ne touche pas à une fenêtre saine")

    // Le contenu arrive, SwiftUI pousse la hauteur idéale : 2142 px.
    fenetre.currentFrame = CGRect(x: 216, y: -1273, width: 1100, height: 2142)
    gardien.apply()

    XCTAssertTrue(
      WindowFrameGuard.fits(fenetre.currentFrame, visible: visible),
      "la fenêtre doit RESTER dans l'écran : \(fenetre.currentFrame)"
    )
    XCTAssertLessThanOrEqual(fenetre.currentFrame.height, visible.height)
    XCTAssertGreaterThanOrEqual(fenetre.currentFrame.minY, visible.minY)
  }

  /// La défense qui n'arrive jamais trop tard : AppKit refuse de lui-même.
  @MainActor
  func testAppKitSeVoitInterdireDeDepasserLEcran() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 869)
    let fenetre = FenetreSimulee(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))

    WindowFrameKeeper(
      target: fenetre, minimum: NSSize(width: 720, height: 480), visibleFrame: { visible }
    ).apply()

    XCTAssertLessThanOrEqual(fenetre.currentContentMaxSize.height, visible.height)
    XCTAssertLessThanOrEqual(fenetre.currentContentMaxSize.width, visible.width)
    XCTAssertNotEqual(fenetre.currentContentMaxSize.height, CGFloat.greatestFiniteMagnitude, "la borne est posée")
  }

  /// Le contenu grandit deux fois de suite : la borne tient à chaque fois, pas
  /// seulement la première.
  @MainActor
  func testLaBorneTientAChaqueAgrandissement() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 869)
    let fenetre = FenetreSimulee(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
    let gardien = WindowFrameKeeper(
      target: fenetre, minimum: NSSize(width: 720, height: 480), visibleFrame: { visible }
    )
    gardien.apply()

    for hauteur in [1500.0, 2142.0, 4000.0] {
      fenetre.currentFrame = CGRect(x: 0, y: -500, width: 1100, height: hauteur)
      gardien.apply()
      XCTAssertTrue(
        WindowFrameGuard.fits(fenetre.currentFrame, visible: visible),
        "après une poussée à \(hauteur) : \(fenetre.currentFrame)"
      )
    }
  }

  /// Rien ne bouge quand rien ne déborde : on ne repositionne pas une fenêtre
  /// que l'utilisateur vient de placer.
  func testAucunAjustementQuandLeCadreTient() {
    let sain = CGRect(x: 100, y: 60, width: 1100, height: 760)
    XCTAssertNil(WindowFrameGuard.adjustment(for: sain, visible: ecran, minimum: minimum))
  }

  func testUnAjustementEstProposeQuandCaDeborde() {
    let deborde = CGRect(x: 216, y: -1273, width: 1100, height: 2142)
    let borne = try! XCTUnwrap(
      WindowFrameGuard.adjustment(for: deborde, visible: ecran, minimum: minimum)
    )
    XCTAssertTrue(WindowFrameGuard.fits(borne, visible: ecran))
  }

  // MARK: - La garde ne doit jamais tuer l'app

  /// Le plantage au lancement : `contentMaxSize` posé à la taille de l'écran
  /// devenait plus petit que le `contentMinSize` du contenu, AppKit levait, et
  /// l'app mourait d'un `SIGABRT`. La propriété qui l'aurait attrapé sans
  /// AppKit : **jamais un maximum sous le minimum**, quelles que soient les
  /// entrées.
  func testLeMaximumNEstJamaisSousLeMinimum() {
    let ecrans = [
      CGSize(width: 1440, height: 869), CGSize(width: 640, height: 400),
      CGSize(width: 3840, height: 2160), CGSize(width: 100, height: 100), .zero,
    ]
    let minima = [
      CGSize(width: 720, height: 480), CGSize(width: 1600, height: 900),
      CGSize(width: 2000, height: 1500), .zero,
    ]
    for ecran in ecrans {
      for minimum in minima {
        let maximum = WindowFrameGuard.safeMaximum(screen: ecran, contentMinimum: minimum)
        XCTAssertGreaterThanOrEqual(
          maximum.width, minimum.width, "écran \(ecran), minimum \(minimum)"
        )
        XCTAssertGreaterThanOrEqual(
          maximum.height, minimum.height, "écran \(ecran), minimum \(minimum)"
        )
      }
    }
  }

  /// Quand le contenu exige plus que l'écran, c'est l'écran qui perd : une
  /// fenêtre un peu trop large est un désagrément, un plantage est une app
  /// morte.
  func testUnContenuPlusLargeQueLEcranGagne() {
    let maximum = WindowFrameGuard.safeMaximum(
      screen: CGSize(width: 1440, height: 869),
      contentMinimum: CGSize(width: 1600, height: 900)
    )
    XCTAssertEqual(maximum.width, 1600)
    XCTAssertEqual(maximum.height, 900)
  }

  /// Le scénario complet du plantage, contre une fenêtre qui refuse comme la
  /// vraie : le gardien ne doit jamais lui faire lever.
  @MainActor
  func testLeGardienNeFaitJamaisLeverLaFenetre() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 869)
    let fenetre = FenetreSimulee(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
    // Le contenu exige plus large que l'écran — le cas exact du plantage.
    fenetre.currentContentMinSize = CGSize(width: 1600, height: 900)

    let gardien = WindowFrameKeeper(
      target: fenetre, minimum: NSSize(width: 720, height: 480), visibleFrame: { visible }
    )
    gardien.apply()
    XCTAssertFalse(fenetre.aLeve, "un maximum sous le minimum tuerait l'app au lancement")

    fenetre.currentFrame = CGRect(x: 0, y: -1273, width: 1100, height: 2142)
    gardien.apply()
    XCTAssertFalse(fenetre.aLeve)
  }
}
