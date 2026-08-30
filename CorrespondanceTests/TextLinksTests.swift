import XCTest
@testable import Correspondance

/// Ce qu'on reçoit dans un message et qu'on doit pouvoir ouvrir d'un clic :
/// une adresse web, un e-mail, un numéro. Le reste du texte n'y touche pas.
final class TextLinksTests: XCTestCase {
  private func urls(in text: String) -> [String] {
    TextLinks.detect(in: text).map { $0.url.absoluteString }
  }

  private func linkedRanges(in text: String) -> [String] {
    TextLinks.detect(in: text).map { String(text[$0.range]) }
  }

  func testHTTPSURLIsDetected() {
    XCTAssertEqual(
      urls(in: "Regarde https://exemple.fr/photos?a=1 avant ce soir"),
      ["https://exemple.fr/photos?a=1"]
    )
  }

  /// Le détecteur propose `http://` pour une adresse sans schéma : on ne renvoie
  /// personne en clair.
  func testBareWWWBecomesHTTPS() {
    XCTAssertEqual(urls(in: "C'est sur www.exemple.fr"), ["https://www.exemple.fr"])
    XCTAssertEqual(linkedRanges(in: "C'est sur www.exemple.fr"), ["www.exemple.fr"])
  }

  func testEmailBecomesMailto() {
    XCTAssertEqual(urls(in: "Écris à malo@exemple.fr stp"), ["mailto:malo@exemple.fr"])
  }

  func testFrenchPhoneNumbersBecomeTel() {
    XCTAssertEqual(urls(in: "Appelle-moi au 06 12 34 56 78"), ["tel:0612345678"])
    XCTAssertEqual(urls(in: "Mon numéro : +33 6 12 34 56 78"), ["tel:+33612345678"])
  }

  func testPlainTextHasNoLink() {
    let text = "On se voit demain à midi, place de la mairie."
    XCTAssertTrue(TextLinks.detect(in: text).isEmpty)
    XCTAssertEqual(String(TextLinks.linkified(text).characters), text)
  }

  func testTwoLinksInTheSameMessage() {
    let text = "Le site https://exemple.fr et l'adresse malo@exemple.fr"
    XCTAssertEqual(urls(in: text), ["https://exemple.fr", "mailto:malo@exemple.fr"])
  }

  /// L'attribut `.link` doit tomber pile sur la plage détectée : c'est lui que
  /// SwiftUI confie à `openURL`, et rien d'autre ne doit devenir cliquable.
  func testLinkAttributeCoversOnlyTheDetectedRange() {
    let text = "Voir https://exemple.fr merci"
    let attributed = TextLinks.linkified(text)
    XCTAssertEqual(String(attributed.characters), text)
    let linked = attributed.runs.filter { $0.link != nil }
    XCTAssertEqual(linked.count, 1)
    let run = try? XCTUnwrap(linked.first)
    XCTAssertEqual(run.map { String(attributed[$0.range].characters) }, "https://exemple.fr")
    XCTAssertEqual(run?.link?.absoluteString, "https://exemple.fr")
  }
}
