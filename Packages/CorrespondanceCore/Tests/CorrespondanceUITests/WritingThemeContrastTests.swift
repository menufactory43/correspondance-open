import XCTest
@testable import CorrespondanceUI

/// LE CONTRAT DE LISIBILITÉ DES THÈMES.
///
/// Un thème « qui donne envie » n'a pas le droit d'être un thème qu'on ne peut
/// pas lire. Chaque jeton sémantique est mesuré ici, thème par thème, contre les
/// surfaces sur lesquelles il atterrit vraiment :
///
/// - texte courant (encre, encre secondaire, encre tertiaire, encre de bulle) :
///   ≥ 4,5:1 — WCAG 2.1 AA, critère 1.4.3 ;
/// - grandes tailles (le corps du fil, ≥ 18 pt) : ≥ 3:1 — même critère ;
/// - composants non textuels (accent porteur d'icône, liseré, sélection) :
///   ≥ 3:1 — critère 1.4.11.
///
/// Les seuils ne sont pas décoratifs : les encres secondaires et l'encre des
/// bulles sortantes sont DÉRIVÉES par `WritingPalette.make` pour les tenir. Si
/// ce banc rougit, c'est qu'une teinte de caractère a bougé trop loin.
final class WritingThemeContrastTests: XCTestCase {
  private let bodyText = 4.5
  private let largeText = 3.0
  private let component = 3.0

  private func assertContrast(
    _ foreground: RGB,
    on background: RGB,
    atLeast minimum: Double,
    _ what: String,
    theme: WritingThemeID,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let ratio = RGB.contrast(foreground, background)
    XCTAssertGreaterThanOrEqual(
      ratio,
      minimum,
      "\(theme.rawValue) — \(what) : \(String(format: "%.2f", ratio)):1 < \(minimum):1",
      file: file,
      line: line
    )
  }

  /// Le texte courant tient AA sur toutes les surfaces où il peut atterrir.
  func testEncresSurToutesLesSurfaces() {
    for id in WritingThemeID.allCases {
      let p = WritingTheme.resolve(id).palette
      for surface in p.textSurfaces {
        assertContrast(p.ink, on: surface, atLeast: bodyText, "encre", theme: id)
        assertContrast(p.inkSecondary, on: surface, atLeast: bodyText, "encre secondaire", theme: id)
        assertContrast(p.inkTertiary, on: surface, atLeast: bodyText, "encre tertiaire", theme: id)
      }
    }
  }

  /// Les bulles : l'encre entrante sur la bulle entrante, l'encre sortante
  /// (calculée) sur l'accent plein.
  func testEncresDesBulles() {
    for id in WritingThemeID.allCases {
      let p = WritingTheme.resolve(id).palette
      assertContrast(p.bubbleInInk, on: p.bubbleIn, atLeast: bodyText, "encre bulle entrante", theme: id)
      assertContrast(p.bubbleOutInk, on: p.bubbleOut, atLeast: bodyText, "encre bulle sortante", theme: id)
      assertContrast(p.badgeInk, on: p.badge, atLeast: bodyText, "encre de pastille", theme: id)
      // Une bulle doit aussi se DÉTACHER du papier, sinon elle n'est pas une bulle.
      assertContrast(p.bubbleIn, on: p.paper, atLeast: 1.06, "bulle entrante sur papier", theme: id)
      assertContrast(p.bubbleOut, on: p.paper, atLeast: component, "bulle sortante sur papier", theme: id)
    }
  }

  /// L'accent porte des icônes, un curseur, des liens : ≥ 3:1 partout où il se
  /// pose. Sur le papier il doit même tenir le texte courant (les liens).
  func testAccent() {
    for id in WritingThemeID.allCases {
      let p = WritingTheme.resolve(id).palette
      assertContrast(p.accent, on: p.paper, atLeast: bodyText, "accent (liens) sur papier", theme: id)
      assertContrast(p.accent, on: p.sidebar, atLeast: component, "accent sur sidebar", theme: id)
      assertContrast(p.accent, on: p.rail, atLeast: component, "accent sur rail", theme: id)
      assertContrast(p.accent, on: p.selection, atLeast: component, "accent sur sélection", theme: id)
      assertContrast(p.caret, on: p.paper, atLeast: component, "curseur sur papier", theme: id)
    }
  }

  /// Le corps du fil est composé ≥ 17,5 pt : le seuil « grandes tailles » suffit
  /// pour la surface de sélection et le liseré, qui ne portent pas de texte.
  func testSurfacesEtLiserés() {
    for id in WritingThemeID.allCases {
      let theme = WritingTheme.resolve(id)
      let p = theme.palette
      XCTAssertGreaterThanOrEqual(theme.bodySize, 17.5, "\(id.rawValue) — corps sous 17,5 pt")
      assertContrast(p.ink, on: p.paper, atLeast: 7.0, "encre sur papier (AAA visé)", theme: id)
      assertContrast(p.ink, on: p.selection, atLeast: largeText, "encre sur sélection", theme: id)
      // Le liseré doit se voir sur les deux surfaces qu'il sépare.
      XCTAssertGreaterThanOrEqual(
        RGB.contrast(p.separator, p.paper), 1.14,
        "\(id.rawValue) — liseré invisible sur le papier"
      )
      // La sidebar et le papier sont DEUX plans : ils ne peuvent pas être
      // identiques, sinon la fenêtre n'a plus de structure.
      XCTAssertGreaterThanOrEqual(
        RGB.contrast(p.sidebar, p.paper), 1.03,
        "\(id.rawValue) — sidebar et papier indiscernables"
      )
    }
  }

  /// Un thème sombre est SOMBRE et un thème clair est CLAIR — et aucun sombre
  /// n'est un gris neutre : le fond garde de la couleur.
  func testIdentiteDesThemes() {
    for id in WritingThemeID.allCases {
      let p = WritingTheme.resolve(id).palette
      XCTAssertEqual(p.isDark, id.prefersDarkChrome, "\(id.rawValue) — clair/sombre incohérent")
      if p.isDark {
        XCTAssertLessThan(p.paper.relativeLuminance, 0.12, "\(id.rawValue) — fond sombre trop clair")
      } else {
        XCTAssertGreaterThan(p.paper.relativeLuminance, 0.70, "\(id.rawValue) — papier clair trop sombre")
      }
      let chroma = max(p.paper.r, p.paper.g, p.paper.b) - min(p.paper.r, p.paper.g, p.paper.b)
      XCTAssertGreaterThan(chroma, 0.008, "\(id.rawValue) — fond gris neutre, sans identité")
    }
  }

  /// La table complète, imprimée : c'est le tableau qu'on relit quand on
  /// retouche une teinte.
  func testImprimeLaTableDesContrastes() {
    for id in WritingThemeID.allCases {
      let p = WritingTheme.resolve(id).palette
      let worst = p.textSurfaces.map { RGB.contrast(p.inkTertiary, $0) }.min() ?? 0
      print(String(
        format: "%-14@ encre/papier %5.2f · secondaire %5.2f · tertiaire(pire) %5.2f · bulle-out %5.2f · accent/papier %5.2f",
        id.rawValue as NSString,
        RGB.contrast(p.ink, p.paper),
        p.textSurfaces.map { RGB.contrast(p.inkSecondary, $0) }.min() ?? 0,
        worst,
        RGB.contrast(p.bubbleOutInk, p.bubbleOut),
        RGB.contrast(p.accent, p.paper)
      ))
    }
  }

  // MARK: - Le calcul lui-même

  func testRapportDeContrasteConnu() {
    XCTAssertEqual(RGB.contrast(.black, .white), 21, accuracy: 0.01)
    XCTAssertEqual(RGB.contrast(.white, .white), 1, accuracy: 0.001)
    // #767676 sur blanc = 4,54:1, la valeur de référence WCAG.
    XCTAssertEqual(RGB.contrast(RGB(0x767676), .white), 4.54, accuracy: 0.02)
  }

  func testPasVersLEncreTientLeSeuil() {
    let paper = RGB(0xFAF4ED)
    let ink = RGB(0x4A4462)
    let derived = RGB.step(on: paper, toward: ink, minRatio: 4.8)
    XCTAssertGreaterThanOrEqual(RGB.contrast(derived, paper), 4.8)
    // Et c'est bien le PLUS PETIT pas : à peine moins, le seuil tombe.
    XCTAssertLessThan(RGB.contrast(paper.mix(ink, 0.80 * mixFactor(paper, ink, derived)), paper), 4.8)
  }

  private func mixFactor(_ from: RGB, _ to: RGB, _ result: RGB) -> Double {
    guard abs(to.r - from.r) > 0.001 else { return 1 }
    return (result.r - from.r) / (to.r - from.r)
  }
}
