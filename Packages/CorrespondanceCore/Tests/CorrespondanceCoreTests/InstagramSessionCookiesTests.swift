import XCTest
@testable import CorrespondanceCore

/// La fenêtre de connexion intégrée ne se teste pas sans navigateur ; la question
/// qu'elle pose, si — « cette session est-elle complète, et à quoi ressemble le JSON
/// que le pont recevra ? ».
final class InstagramSessionCookiesTests: XCTestCase {
  private let complete = [
    "sessionid": "42%3Aabc%3A1",
    "ds_user_id": "17841400000000001",
    "csrftoken": "jeton-csrf",
    "mid": "Zabc",
    "ig_did": "AAAA-BBBB",
  ]

  func testCompleteSessionIsAccepted() throws {
    let session = try XCTUnwrap(InstagramSessionCookies(rawCookies: complete))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
  }

  /// Tant que le trio manque, l'utilisateur est encore sur le formulaire (ou en 2FA) :
  /// rien ne doit partir au bot.
  func testIncompleteSessionIsRejected() {
    for missing in ["sessionid", "ds_user_id", "csrftoken"] {
      var partial = complete
      partial[missing] = nil
      XCTAssertNil(
        InstagramSessionCookies(rawCookies: partial),
        "sans \(missing), la session ne doit pas être considérée complète"
      )
    }
    // Un cookie vide vaut un cookie absent : Instagram en pose avant la connexion.
    var blank = complete
    blank["sessionid"] = ""
    XCTAssertNil(InstagramSessionCookies(rawCookies: blank))
    XCTAssertNil(InstagramSessionCookies(rawCookies: [:]))
  }

  /// `mid` et `ig_did` sont posés dès la première page, `rur`/`shbid`/`shbts` pas partout :
  /// leur absence ne bloque rien, leur présence part quand même.
  func testOptionalCookiesTravelButAreNotRequired() throws {
    let minimal = try XCTUnwrap(
      InstagramSessionCookies(rawCookies: [
        "sessionid": "s", "ds_user_id": "1", "csrftoken": "c",
      ])
    )
    XCTAssertEqual(Set(minimal.values.keys), ["sessionid", "ds_user_id", "csrftoken"])

    var withShards = complete
    withShards["rur"] = "PRN"
    withShards["shbid"] = "12345"
    withShards["shbts"] = "1700000000"
    let full = try XCTUnwrap(InstagramSessionCookies(rawCookies: withShards))
    XCTAssertEqual(full.values["rur"], "PRN")
    XCTAssertEqual(full.values["shbts"], "1700000000")
  }

  /// Le magasin de cookies du navigateur intégré peut contenir d'autres domaines
  /// (redirections Facebook, CDN) : eux n'ont rien à faire dans la charge utile.
  func testForeignCookiesAreIgnored() throws {
    var cookies = complete.map { cookie(name: $0.key, value: $0.value, domain: ".instagram.com") }
    cookies.append(cookie(name: "c_user", value: "999", domain: ".facebook.com"))
    cookies.append(cookie(name: "csrftoken", value: "autre-site", domain: ".exemple.fr"))
    cookies.append(cookie(name: "datr", value: "xyz", domain: ".instagram.com"))

    let session = try XCTUnwrap(InstagramSessionCookies(httpCookies: cookies))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
    XCTAssertEqual(session.values["csrftoken"], "jeton-csrf")
    XCTAssertNil(session.values["datr"])

    XCTAssertTrue(InstagramSessionCookies.isInstagramDomain("www.instagram.com"))
    XCTAssertTrue(InstagramSessionCookies.isInstagramDomain(".instagram.com"))
    XCTAssertFalse(InstagramSessionCookies.isInstagramDomain("faux-instagram.com"))
  }

  /// Ce que le bot lit : un objet JSON plat, avec les clés qu'il réclame.
  func testJSONPayloadCarriesTheExpectedKeys() throws {
    let session = try XCTUnwrap(InstagramSessionCookies(rawCookies: complete))
    let payload = session.jsonPayload
    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
    )
    XCTAssertEqual(decoded, complete)
    // Clés triées : la charge utile est reproductible, donc diffable en cas de panne.
    XCTAssertTrue(payload.hasPrefix("{\"csrftoken\""))
  }

  private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
    HTTPCookie(properties: [
      .name: name, .value: value, .domain: domain, .path: "/",
    ])!
  }
}
