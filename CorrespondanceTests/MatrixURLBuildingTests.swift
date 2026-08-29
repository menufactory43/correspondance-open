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

final class MatrixDMPeerTests: XCTestCase {
  func testOwnGhostIsExcludedFromDMAndLIDIsNotAPhone() {
    var model = MatrixRoomModel(roomID: "!dm:correspondance.local")
    model.network = .whatsapp
    model.bridgeRoomType = "dm"
    model.bridgeChannelID = "81540071608362@lid"
    model.members["@meffysto:correspondance.local"] = .init(displayName: "meffysto", membership: "join")
    model.members["@whatsappbot:correspondance.local"] = .init(displayName: "WhatsApp bridge bot", membership: "join")
    model.members["@whatsapp_lid-157522891694176:correspondance.local"] = .init(displayName: "Malo", membership: "join")
    model.members["@whatsapp_lid-81540071608362:correspondance.local"] = .init(displayName: "+33699000002", membership: "join")
    let remotes = model.remoteMembers(selfUserID: "@meffysto:correspondance.local")
    XCTAssertEqual(remotes.map(\.userID), ["@whatsapp_lid-81540071608362:correspondance.local"])
    XCTAssertFalse(model.isGroup(selfUserID: "@meffysto:correspondance.local"))
    XCTAssertEqual(model.title(selfUserID: "@meffysto:correspondance.local"), "+33699000002")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Malo (WA)"), "Malo")
    XCTAssertNil(MatrixIdentity.phoneNumber(in: "lid-81540071608362"))
  }
}
