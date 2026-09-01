import XCTest
@testable import CorrespondanceCore

/// L'arobase que les ponts rangent dans la pilule HTML : on la rend au corps.
final class MatrixMentionsTests: XCTestCase {
  private func pill(_ user: String, _ name: String) -> String {
    "<a href=\"https://matrix.to/#/\(user)\">\(name)</a>"
  }

  func testLeCorpsSansPiluleNeBougePas() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(in: "Salut les gars", formattedBody: "Salut les gars"),
      "Salut les gars"
    )
  }

  func testSansFormattedBodyLeCorpsNeBougePas() {
    XCTAssertEqual(MatrixMentions.restoringPills(in: "Salut Azer", formattedBody: nil), "Salut Azer")
  }

  /// Le vrai message : sept mentions Signal, dont un nom en trois mots.
  func testChaquePiluleRetrouveSonArobase() {
    let names = ["21 Rue des Satochis", "Azer", "François", "Meff Meff", "Nicolas_MVD", "Pivi", "Romain"]
    let body = "Salut les gars " + names.joined(separator: " ") + "\n\nVous êtes chauds??"
    let html = "Salut les gars "
      + names.enumerated().map { pill("@signal_\($0.offset):relais", $0.element) }.joined(separator: " ")
      + "<br><br>Vous êtes chauds??"
    XCTAssertEqual(
      MatrixMentions.restoringPills(in: body, formattedBody: html),
      "Salut les gars " + names.map { "@" + $0 }.joined(separator: " ") + "\n\nVous êtes chauds??"
    )
  }

  func testUneArobaseDejaPoseeNEstPasDoublee() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(in: "coucou @Azer", formattedBody: "coucou " + pill("@a:b", "Azer")),
      "coucou @Azer"
    )
  }

  func testLeMemeNomMentionneDeuxFoisPrendDeuxArobases() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(
        in: "Azer et Azer",
        formattedBody: pill("@a:b", "Azer") + " et " + pill("@a:b", "Azer")
      ),
      "@Azer et @Azer"
    )
  }

  func testUnNomQuiTraineDansLaPhraseNePrendQuUneArobase() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(
        in: "Azer tu demandes à Azer",
        formattedBody: pill("@a:b", "Azer") + " tu demandes à Azer"
      ),
      "@Azer tu demandes à Azer"
    )
  }

  func testUnePiluleDeSalonNEstPasUneMention() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(
        in: "voir Le salon",
        formattedBody: "voir <a href=\"https://matrix.to/#/!abc:relais\">Le salon</a>"
      ),
      "voir Le salon"
    )
  }

  func testLesPilulesDeLaCitationNeComptentPas() {
    let html = "<mx-reply><blockquote>" + pill("@a:b", "Azer") + " salut</blockquote></mx-reply>oui"
    XCTAssertEqual(MatrixMentions.restoringPills(in: "Azer oui", formattedBody: html), "Azer oui")
  }

  func testLeNomEchappeEstRendu() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(
        in: "salut Rock & Roll",
        formattedBody: "salut " + pill("@a:b", "Rock &amp; Roll")
      ),
      "salut @Rock & Roll"
    )
  }

  func testUnNomCollASonVoisinNestPasLaMention() {
    XCTAssertEqual(
      MatrixMentions.restoringPills(
        in: "Azerty puis Azer",
        formattedBody: "Azerty puis " + pill("@a:b", "Azer")
      ),
      "Azerty puis @Azer"
    )
  }
}
