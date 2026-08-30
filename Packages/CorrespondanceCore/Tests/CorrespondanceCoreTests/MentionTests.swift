import XCTest
@testable import CorrespondanceCore

/// Le « @ » du composer : quand il ouvre le menu, qui il propose, ce qu'il écrit.
final class MentionTests: XCTestCase {
  private func person(_ name: String) -> MentionCandidate {
    MentionCandidate(
      id: name, name: name,
      avatar: .avatarStub(network: .signal, address: name, title: name)
    )
  }

  private let people = ["Pastèque", "Maman maison", "Papa", "Hugo Pauline", "meffysto"]

  // MARK: - Détection

  func testUnArobaseSeulOuvreLeMenuSansRequete() {
    let token = MentionParser.activeToken(in: "@")
    XCTAssertEqual(token?.query, "")
  }

  func testUnArobaseApresUnBlancOuvreLeMenuAvecLaRequete() {
    XCTAssertEqual(MentionParser.activeToken(in: "salut @pa")?.query, "pa")
  }

  func testUneAdresseEmailNOuvrePasLeMenu() {
    XCTAssertNil(MentionParser.activeToken(in: "écris à meffysto@gmail.com"))
  }

  func testUneMentionPoseeSuivieDUnBlancRefermeLeMenu() {
    XCTAssertNil(MentionParser.activeToken(in: "@Pastèque "))
  }

  func testUnRetourALaLigneApresLArobaseRefermeLeMenu() {
    XCTAssertNil(MentionParser.activeToken(in: "@pa\nbonjour"))
  }

  // MARK: - Filtrage

  func testSansRequeteToutLeMondeEstPropose() {
    let all = people.map(person)
    XCTAssertEqual(MentionParser.matches(all, query: "").map(\.name), people)
  }

  func testLaRequeteFiltreParPrefixeDeNomOuDeMot() {
    let all = people.map(person)
    XCTAssertEqual(MentionParser.matches(all, query: "pa").map(\.name), ["Pastèque", "Papa", "Hugo Pauline"])
    XCTAssertEqual(MentionParser.matches(all, query: "maman m").map(\.name), ["Maman maison"])
  }

  func testLeFiltreIgnoreLaCasseEtLesAccents() {
    let all = [person("Éléonore")]
    XCTAssertEqual(MentionParser.matches(all, query: "ele").count, 1)
  }

  // MARK: - Insertion

  func testChoisirRemplaceLaRequeteParLeNomEtUneEspace() {
    let text = "salut @pa"
    let token = MentionParser.activeToken(in: text)!
    XCTAssertEqual(MentionParser.insert(person("Papa"), replacing: token, in: text), "salut @Papa ")
  }
}
