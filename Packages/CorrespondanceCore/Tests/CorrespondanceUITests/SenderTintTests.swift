import XCTest
@testable import CorrespondanceUI

/// La couleur d'un nom ne se tire pas au sort : deux appareils, deux lancements,
/// deux plateformes doivent poser la même encre sur la même personne.
final class SenderTintTests: XCTestCase {
  private let theme = WritingTheme.resolve(.papier)

  func testLaMemeSignatureDonneLaMemeEncre() {
    XCTAssertEqual(
      SenderTint.color(for: "Clara Nguyen", theme: theme),
      SenderTint.color(for: "Clara Nguyen", theme: theme)
    )
  }

  func testDeuxNomsNePartagentPasLEncre() {
    XCTAssertNotEqual(
      SenderTint.color(for: "Clara Nguyen", theme: theme),
      SenderTint.color(for: "Bob Dupuis", theme: theme)
    )
  }

  func testLEncreSuitLAmbianceDuTheme() {
    XCTAssertNotEqual(
      SenderTint.color(for: "Clara Nguyen", theme: theme),
      SenderTint.color(for: "Clara Nguyen", theme: WritingTheme.resolve(.encreDeNuit))
    )
  }
}
