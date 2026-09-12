import XCTest

@testable import CorrespondanceCore

/// Ce qui, dans un message, s'adresse à moi — la seule chose qu'un fil muet
/// laisse encore passer.
final class PersonalMessageTests: XCTestCase {
  private let moi = ["Lucas", "meffysto"]

  func testNamedInTheMiddleOfASentence() {
    XCTAssertTrue(PersonalMessage.mentions("Tu peux regarder Lucas ?", names: moi))
    XCTAssertTrue(PersonalMessage.mentions("@meffysto t'en penses quoi", names: moi))
  }

  /// Un mot entier, pas un fragment : sinon toute personne dont le nom me
  /// contient me sonnerait dessus.
  func testAFragmentIsNotAMention() {
    XCTAssertFalse(PersonalMessage.mentions("Lucastin a répondu", names: moi))
    XCTAssertFalse(PersonalMessage.mentions("meffysto42 est un autre compte", names: moi))
  }

  /// Les ponts écrivent le nom comme le réseau d'origine l'écrit : la casse et
  /// les accents ne doivent pas décider d'une notification.
  func testCaseAndAccentsDoNotDecide() {
    XCTAssertTrue(PersonalMessage.mentions("lucas tu viens ?", names: ["Lucas"]))
    XCTAssertTrue(PersonalMessage.mentions("Merci LÙCAS", names: ["Lucas"]))
    XCTAssertTrue(PersonalMessage.mentions("ok lucàs", names: ["Lucas"]))
  }

  func testNoNamesMeansNoMention() {
    XCTAssertFalse(PersonalMessage.mentions("Lucas ?", names: []))
    XCTAssertFalse(PersonalMessage.mentions("", names: moi))
  }

  /// Un nom d'une lettre ferait sonner tout le fil.
  func testVeryShortNamesAreIgnored() {
    XCTAssertFalse(PersonalMessage.mentions("a b c", names: ["a"]))
  }

  /// « Lucas Dupont » se dit aussi « Lucas » ; un identifiant technique,
  /// lui, ne se dit pas — le chercher dans un texte ne donnerait que des faux.
  func testNamesDerivedFromProfile() {
    let names = PersonalMessage.names(displayName: "Lucas Dupont", userLocalpart: "meffysto")
    XCTAssertTrue(names.contains("Lucas Dupont"))
    XCTAssertTrue(names.contains("Lucas"))
    XCTAssertTrue(names.contains("meffysto"))

    let technique = PersonalMessage.names(displayName: nil, userLocalpart: "whatsapp_lid-1234")
    XCTAssertTrue(technique.isEmpty, "un identifiant de pont n'est pas un nom")
  }
}
