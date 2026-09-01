import XCTest
@testable import CorrespondanceCore

final class MediaAlbumLayoutTests: XCTestCase {
  func testUnePhotoSeuleNaPasDeMosaique() {
    XCTAssertNil(MediaAlbumLayout.plan(count: 0))
    XCTAssertNil(MediaAlbumLayout.plan(count: 1))
  }

  func testDeuxPhotosCoteACote() throws {
    let plan = try XCTUnwrap(MediaAlbumLayout.plan(count: 2))
    XCTAssertEqual(plan.columns.map(\.tiles.count), [1, 1])
    XCTAssertEqual(plan.columns.map(\.widthFraction), [0.5, 0.5])
    XCTAssertEqual(plan.aspectRatio, 2)
  }

  func testTroisPhotosUneGrandeEtDeuxPetites() throws {
    let plan = try XCTUnwrap(MediaAlbumLayout.plan(count: 3))
    XCTAssertEqual(plan.columns[0].tiles.map(\.index), [0])
    XCTAssertEqual(plan.columns[1].tiles.map(\.index), [1, 2])
    XCTAssertGreaterThan(plan.columns[0].widthFraction, plan.columns[1].widthFraction)
    // La grande fait deux tiers de large sur toute la hauteur, les petites un
    // tiers sur une demi-hauteur : les trois tuiles sont carrées.
    XCTAssertEqual(plan.aspectRatio, 1.5)
  }

  func testQuatrePhotosEnCarreEtLectureDeGaucheADroite() throws {
    let plan = try XCTUnwrap(MediaAlbumLayout.plan(count: 4))
    XCTAssertEqual(plan.columns[0].tiles.map(\.index), [0, 2])
    XCTAssertEqual(plan.columns[1].tiles.map(\.index), [1, 3])
    XCTAssertEqual(plan.aspectRatio, 1)
    XCTAssertEqual(plan.columns.flatMap(\.tiles).map(\.hiddenCount), [0, 0, 0, 0])
  }

  func testAuDelaDeQuatreLaDerniereTuilePorteLeReste() throws {
    let plan = try XCTUnwrap(MediaAlbumLayout.plan(count: 7))
    XCTAssertEqual(plan.columns.flatMap(\.tiles).map(\.index), [0, 2, 1, 3])
    XCTAssertEqual(plan.columns[1].tiles.last?.hiddenCount, 3)
  }
}

final class MediaAlbumsTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func photo(
    _ rank: Int,
    after seconds: TimeInterval,
    sender: String = "@nina:s",
    reactions: [MessageReaction] = []
  ) -> ChatMessage {
    ChatMessage(
      id: "$photo\(rank)",
      conversationID: "!c",
      network: .whatsapp,
      text: "",
      sentAt: start.addingTimeInterval(seconds),
      isFromMe: false,
      senderID: sender,
      attachments: [MessageAttachment(id: "mxc://s/\(rank)", contentType: "image/jpeg")],
      reactions: reactions
    )
  }

  private func line(_ text: String, after seconds: TimeInterval) -> ChatMessage {
    ChatMessage(
      id: "$txt\(seconds)",
      conversationID: "!c",
      network: .whatsapp,
      text: text,
      sentAt: start.addingTimeInterval(seconds),
      isFromMe: false,
      senderID: "@nina:s"
    )
  }

  func testQuatrePhotosDAffileeNeFontQuUneBulle() {
    let merged = MediaAlbums.merged([
      photo(1, after: 0), photo(2, after: 3), photo(3, after: 5), photo(4, after: 9),
    ])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].id, "$photo1")
    XCTAssertEqual(merged[0].attachments.count, 4)
  }

  func testLesReactionsDesPhotosSeRetrouventSurLAlbum() {
    let merged = MediaAlbums.merged([
      photo(1, after: 0),
      photo(2, after: 2, reactions: [MessageReaction(emoji: "❤️", senders: ["Yann"])]),
    ])
    XCTAssertEqual(merged.first?.reactions.map(\.emoji), ["❤️"])
  }

  func testUnMotEntreDeuxPhotosLesSepare() {
    let merged = MediaAlbums.merged([photo(1, after: 0), line("regarde", after: 2), photo(2, after: 4)])
    XCTAssertEqual(merged.map(\.attachments.count), [1, 0, 1])
  }

  func testAuDelaDeLaMinuteCeNestPlusLeMemeEnvoi() {
    let merged = MediaAlbums.merged([photo(1, after: 0), photo(2, after: 120)])
    XCTAssertEqual(merged.count, 2)
  }

  func testDeuxAuteursNeMelangentPasLeursPhotos() {
    let merged = MediaAlbums.merged([photo(1, after: 0), photo(2, after: 2, sender: "@yann:s")])
    XCTAssertEqual(merged.count, 2)
  }
}
