import XCTest
@testable import CorrespondanceCore

/// Le contrat du pusher, mot à mot.
///
/// Ce corps-là est le seul point où l'app iOS, Synapse et Sygnal doivent
/// s'accorder — un `app_id` de travers, et le Relais appelle Sygnal pour rien.
/// Rien de tout ça ne se voit à l'exécution : la seule façon de le savoir faux
/// est de ne recevoir aucune notification, sans un mot d'explication.
final class PusherTests: XCTestCase {
  private let sygnal = URL(string: "http://sygnal:5000/_matrix/push/v1/notify")!

  private func body(_ json: MatrixJSON) throws -> [String: Any] {
    let data = try JSONEncoder().encode(json)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testPusherBodyMatchesTheClientServerSpec() throws {
    let json = MatrixClient.pusherBody(
      pushkey: "a1b2c3",
      sygnalURL: sygnal,
      deviceDisplayName: "iPhone de meffysto"
    )
    let dict = try body(json)
    XCTAssertEqual(dict["app_id"] as? String, "com.correspondance.ios")
    XCTAssertEqual(dict["kind"] as? String, "http")
    XCTAssertEqual(dict["pushkey"] as? String, "a1b2c3")
    XCTAssertEqual(dict["app_display_name"] as? String, "Correspondance")
    XCTAssertEqual(dict["device_display_name"] as? String, "iPhone de meffysto")
    XCTAssertEqual(dict["lang"] as? String, "fr")
    // `append: false` — un jeton APNs qui tourne ne doit pas laisser derrière
    // lui autant de pushers morts que de rotations.
    XCTAssertEqual(dict["append"] as? Bool, false)

    let data = try XCTUnwrap(dict["data"] as? [String: Any])
    // L'URL est celle que SYNAPSE voit : un nom de service Docker. L'iPhone
    // n'a rien à y faire, et ne saurait pas la résoudre.
    XCTAssertEqual(data["url"] as? String, "http://sygnal:5000/_matrix/push/v1/notify")
    // Le push ne porte pas le texte : il réveille, l'appareil lit (décision 7).
    XCTAssertEqual(data["format"] as? String, "event_id_only")
  }

  /// `kind: null`, et pas un pusher absent : c'est ainsi que la spécification
  /// dit « oublie cet appareil ». Il faut donc un vrai `null` dans le JSON.
  func testRemovalBodyCarriesAJSONNullKind() throws {
    let json = MatrixClient.pusherRemovalBody(pushkey: "a1b2c3")
    let data = try JSONEncoder().encode(json)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.contains("\"kind\":null"), "corps envoyé : \(text)")

    let dict = try body(json)
    XCTAssertEqual(dict["app_id"] as? String, "com.correspondance.ios")
    XCTAssertEqual(dict["pushkey"] as? String, "a1b2c3")
    XCTAssertTrue(dict["kind"] is NSNull)
  }

  func testPushkeyIsBase64LikeElement() {
    let token = Data([0x00, 0x0f, 0xa1, 0xff])
    XCTAssertEqual(MatrixClient.pushkey(fromAPNSToken: token), "AA+h/w==")
    XCTAssertEqual(MatrixClient.pushkey(fromAPNSToken: Data()), "")
  }

  // MARK: - URL

  func testPusherPathIsTheV3Endpoint() {
    XCTAssertEqual(MatrixClient.pushersSetPath, "/_matrix/client/v3/pushers/set")
  }

  /// L'extension de notification n'a que `room_id` et `event_id` : il lui faut
  /// une URL correcte du premier coup, sans quoi elle affiche son repli.
  func testRoomEventURLEncodesTheSigils() {
    let base = URL(string: "http://100.64.0.7:8008")!
    let url = MatrixClient.makeURL(
      base: base,
      path: MatrixClient.roomEventPath(
        roomID: "!dm-alice:correspondance.local",
        eventID: "$msg-alice-1"
      )
    )
    XCTAssertEqual(
      url?.absoluteString,
      "http://100.64.0.7:8008/_matrix/client/v3/rooms/%21dm-alice%3Acorrespondance.local/event/%24msg-alice-1"
    )
  }
}
