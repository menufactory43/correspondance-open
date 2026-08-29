import XCTest
@testable import Correspondance
final class MatrixURLBuildingTests: XCTestCase {
  func testRoomIDIsEncodedExactlyOnce() {
    let base = URL(string: "http://relais.exemple.ts.net:8008")!
    let roomID = "!ArZRavcBGHSkVOXsFx:correspondance.local"
    let url = MatrixClient.makeURL(
      base: base,
      path: "/_matrix/client/v3/rooms/\(MatrixClient.escape(roomID))/send/m.room.message/txn",
      query: [URLQueryItem(name: "dir", value: "b")]
    )
    XCTAssertEqual(
      url?.absoluteString,
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/rooms/%21ArZRavcBGHSkVOXsFx%3Acorrespondance.local/send/m.room.message/txn?dir=b"
    )
  }

  func testTrailingSlashOnHomeserverIsTolerated() {
    let base = URL(string: "http://h.example/")!
    XCTAssertEqual(
      MatrixClient.makeURL(base: base, path: "/_matrix/client/versions")?.absoluteString,
      "http://h.example/_matrix/client/versions"
    )
  }
}
