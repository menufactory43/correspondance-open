import XCTest
@testable import CorrespondanceCore

final class SharedPostTests: XCTestCase {
  private func message(_ text: String, attachments: [MessageAttachment] = []) -> ChatMessage {
    ChatMessage(
      id: "$1",
      conversationID: "!c",
      network: .instagram,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_700_000_000),
      isFromMe: false,
      attachments: attachments
    )
  }

  /// Le cas nu du pont : un lien Markdown, rien d'autre, et le reel en vidéo.
  func testReelSansLegende() throws {
    let text = "[https://www.instagram.com/reel/DbtNjyPoF0Q/]"
      + "(https://www.instagram.com/reel/DbtNjyPoF0Q/?id=3957879281264123152_72760849859&is_sponsored=false)"
    let reel = MessageAttachment(id: "mxc://s/reel", contentType: "video/mp4", localPath: nil)
    let post = try XCTUnwrap(SharedPost.parse(message(text, attachments: [reel])))
    XCTAssertEqual(post.url.absoluteString, "https://www.instagram.com/reel/DbtNjyPoF0Q/")
    XCTAssertEqual(post.kind, .reel)
    XCTAssertNil(post.author)
    XCTAssertNil(post.caption)
    XCTAssertEqual(post.media?.id, "mxc://s/reel")
    XCTAssertEqual(post.previewText, "Reel Instagram")
  }

  func testAuteurEtLegendeSortentDuGras() throws {
    let text = "**menbase.fr Dans la plupart des milieux de travail, traiter quelqu'un de « chauve » serait géné…**\n"
      + "[https://www.instagram.com/p/ABC/](https://www.instagram.com/p/ABC/?id=42)"
    let post = try XCTUnwrap(SharedPost.parse(message(text)))
    XCTAssertEqual(post.author, "menbase.fr")
    XCTAssertEqual(post.kind, .post)
    XCTAssertEqual(
      post.caption,
      "Dans la plupart des milieux de travail, traiter quelqu'un de « chauve » serait géné…"
    )
    XCTAssertEqual(post.url.absoluteString, "https://www.instagram.com/p/ABC/")
    XCTAssertEqual(post.previewText, "Publication Instagram")
  }

  func testLApercuDeLaFileNommeLeReel() {
    let text = "**nina.roche Trois jours en Corse**\n"
      + "[https://www.instagram.com/reel/XY/](https://www.instagram.com/reel/XY/?id=7)"
    XCTAssertEqual(message(text).sidebarPreviewText, "Reel de nina.roche")
  }

  func testUnePhraseAutourDUnLienResteUnePhrase() {
    let text = "Regarde ça : [un reel](https://www.instagram.com/reel/XY/?id=7) c'est fou"
    XCTAssertNil(SharedPost.parse(message(text)))
  }

  func testUnLienOrdinaireNEstPasUnPartage() {
    XCTAssertNil(SharedPost.parse(message("https://www.instagram.com/reel/XY/")))
    XCTAssertNil(SharedPost.parse(message("[le site](https://exemple.fr/p/XY)")))
    XCTAssertNil(SharedPost.parse(message("[le profil](https://www.instagram.com/nina/)")))
  }

  /// Un album de photos n'est pas un post partagé : le pont n'en joint qu'une.
  func testPlusieursMediasEcartentLeCas() {
    let text = "[https://www.instagram.com/reel/XY/](https://www.instagram.com/reel/XY/?id=7)"
    let two = [
      MessageAttachment(id: "a", contentType: "image/jpeg"),
      MessageAttachment(id: "b", contentType: "image/jpeg"),
    ]
    XCTAssertNil(SharedPost.parse(message(text, attachments: two)))
  }
}
