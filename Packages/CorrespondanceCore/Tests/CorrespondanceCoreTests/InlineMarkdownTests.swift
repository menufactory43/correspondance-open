import XCTest
@testable import CorrespondanceCore

final class InlineMarkdownTests: XCTestCase {
  private func plain(_ text: String) -> String? {
    InlineMarkdown.attributed(text).map { String($0.characters) }
  }

  func testUnMessageOrdinaireNEstPasTouche() {
    for ordinary in [
      "On se voit à 14h ?",
      "2 * 3 * 4 = 24",
      "https://exemple.fr/mon_article_a_lire",
      "a_b_c",
      "Il a dit *",
      "print(x) # pas de code ici",
    ] {
      XCTAssertNil(InlineMarkdown.attributed(ordinary), ordinary)
    }
  }

  func testGrasItaliqueBarreEtCode() {
    XCTAssertEqual(plain("**Nina** a dit"), "Nina a dit")
    XCTAssertEqual(plain("c'est _vraiment_ bien"), "c'est vraiment bien")
    XCTAssertEqual(plain("c'est *vraiment* bien"), "c'est vraiment bien")
    XCTAssertEqual(plain("~~annulé~~ reporté"), "annulé reporté")
    XCTAssertEqual(plain("tape `git status`"), "tape git status")
  }

  /// Le lien nommé : le libellé reste, l'adresse passe en attribut.
  func testLeLienNommeGardeSonLibelle() throws {
    let attributed = try XCTUnwrap(InlineMarkdown.attributed("[le site](https://exemple.fr)"))
    XCTAssertEqual(String(attributed.characters), "le site")
    XCTAssertEqual(attributed.runs.first?.link?.absoluteString, "https://exemple.fr")
  }

  func testLesRetoursALaLigneSurvivent() {
    XCTAssertEqual(plain("**Nina**\nDeuxième ligne\nTroisième"), "Nina\nDeuxième ligne\nTroisième")
  }
}
