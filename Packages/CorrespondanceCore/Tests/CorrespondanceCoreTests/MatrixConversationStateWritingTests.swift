import XCTest
@testable import CorrespondanceCore

/// Les écritures d'état vers le Relais : URL exacte et corps exact. Aucun appel
/// réseau — c'est le contrat que la phase iOS reprendra mot pour mot.
final class MatrixConversationStateWritingTests: XCTestCase {
  private let base = URL(string: "http://relais.exemple.ts.net:8008")!
  private let user = "@meffysto:correspondance.local"
  private let room = "!ArZRavcBGHSkVOXsFx:correspondance.local"

  private func absolute(_ path: String) -> String? {
    MatrixClient.makeURL(base: base, path: path)?.absoluteString
  }

  private func encoded(_ json: MatrixJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: (try? encoder.encode(json)) ?? Data(), encoding: .utf8) ?? ""
  }

  func testFavouriteTagURL() {
    XCTAssertEqual(
      absolute(MatrixClient.tagPath(userID: user, roomID: room, tag: "m.favourite")),
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/user/%40meffysto%3Acorrespondance.local/rooms/%21ArZRavcBGHSkVOXsFx%3Acorrespondance.local/tags/m.favourite"
    )
  }

  func testArchivedTagURLUsesOurNamespace() {
    XCTAssertEqual(
      absolute(MatrixClient.tagPath(userID: user, roomID: room, tag: ConversationStateKeys.archivedTag)),
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/user/%40meffysto%3Acorrespondance.local/rooms/%21ArZRavcBGHSkVOXsFx%3Acorrespondance.local/tags/fr.correspondance.archived"
    )
  }

  func testRoomAccountDataURL() {
    XCTAssertEqual(
      absolute(MatrixClient.roomAccountDataPath(userID: user, roomID: room, type: ConversationStateKeys.draftType)),
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/user/%40meffysto%3Acorrespondance.local/rooms/%21ArZRavcBGHSkVOXsFx%3Acorrespondance.local/account_data/fr.correspondance.draft"
    )
  }

  func testGlobalAccountDataURL() {
    XCTAssertEqual(
      absolute(MatrixClient.accountDataPath(userID: user, type: ConversationStateKeys.mergedContactsType)),
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/user/%40meffysto%3Acorrespondance.local/account_data/fr.correspondance.merged_contacts"
    )
  }

  func testPushRuleURLIsGlobalRoomScoped() {
    XCTAssertEqual(
      absolute(MatrixClient.roomPushRulePath(roomID: room)),
      "http://relais.exemple.ts.net:8008/_matrix/client/v3/pushrules/global/room/%21ArZRavcBGHSkVOXsFx%3Acorrespondance.local"
    )
  }

  func testTagBodyIsEmptyWithoutOrder() {
    XCTAssertEqual(encoded(MatrixClient.tagBody(order: nil)), "{}")
    XCTAssertEqual(encoded(MatrixClient.tagBody(order: 0.5)), "{\"order\":0.5}")
  }

  /// `dont_notify` est déprécié : c'est la liste vide qui coupe les push.
  func testMutePushRuleBodyIsAnEmptyActionList() {
    XCTAssertEqual(encoded(MatrixClient.mutePushRuleBody()), "{\"actions\":[]}")
  }
}
