import XCTest
@testable import CorrespondanceCore

/// La fenêtre de connexion intégrée ne se teste pas sans navigateur ; la question
/// qu'elle pose, si — « cette session est-elle complète, et à quoi ressemble le JSON
/// que le pont recevra ? ». Deux profils, un seul type : ce qui vaut pour Instagram
/// doit valoir pour Messenger, aux clés et au domaine près.
final class BridgeSessionCookiesTests: XCTestCase {
  private let complete = [
    "sessionid": "42%3Aabc%3A1",
    "ds_user_id": "17841400000000001",
    "csrftoken": "jeton-csrf",
    "mid": "Zabc",
    "ig_did": "AAAA-BBBB",
  ]

  func testCompleteSessionIsAccepted() throws {
    let session = try XCTUnwrap(BridgeSessionCookies(rawCookies: complete, profile: .instagram))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
  }

  /// Tant que le trio manque, l'utilisateur est encore sur le formulaire (ou en 2FA) :
  /// rien ne doit partir au bot.
  func testIncompleteSessionIsRejected() {
    for missing in ["sessionid", "ds_user_id", "csrftoken"] {
      var partial = complete
      partial[missing] = nil
      XCTAssertNil(
        BridgeSessionCookies(rawCookies: partial, profile: .instagram),
        "sans \(missing), la session ne doit pas être considérée complète"
      )
    }
    // Un cookie vide vaut un cookie absent : Instagram en pose avant la connexion.
    var blank = complete
    blank["sessionid"] = ""
    XCTAssertNil(BridgeSessionCookies(rawCookies: blank, profile: .instagram))
    XCTAssertNil(BridgeSessionCookies(rawCookies: [:], profile: .instagram))
  }

  /// `mid` et `ig_did` sont posés dès la première page, `rur`/`shbid`/`shbts` pas partout :
  /// leur absence ne bloque rien, leur présence part quand même.
  func testOptionalCookiesTravelButAreNotRequired() throws {
    let minimal = try XCTUnwrap(
      BridgeSessionCookies(
        rawCookies: ["sessionid": "s", "ds_user_id": "1", "csrftoken": "c"],
        profile: .instagram
      )
    )
    XCTAssertEqual(Set(minimal.values.keys), ["sessionid", "ds_user_id", "csrftoken"])

    var withShards = complete
    withShards["rur"] = "PRN"
    withShards["shbid"] = "12345"
    withShards["shbts"] = "1700000000"
    let full = try XCTUnwrap(BridgeSessionCookies(rawCookies: withShards, profile: .instagram))
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

    let session = try XCTUnwrap(BridgeSessionCookies(httpCookies: cookies, profile: .instagram))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
    XCTAssertEqual(session.values["csrftoken"], "jeton-csrf")
    XCTAssertNil(session.values["datr"])

    XCTAssertTrue(BridgeSessionCookies.Profile.instagram.acceptsDomain("www.instagram.com"))
    XCTAssertTrue(BridgeSessionCookies.Profile.instagram.acceptsDomain(".instagram.com"))
    XCTAssertFalse(BridgeSessionCookies.Profile.instagram.acceptsDomain("faux-instagram.com"))
  }

  /// Ce que le bot lit : un objet JSON plat, avec les clés qu'il réclame.
  func testJSONPayloadCarriesTheExpectedKeys() throws {
    let session = try XCTUnwrap(BridgeSessionCookies(rawCookies: complete, profile: .instagram))
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

// MARK: - Messenger

/// Le profil Facebook, tel que `FBRequiredCookies` le décrit dans
/// `pkg/messagix/cookies` de mautrix/meta : `xs`, `c_user` et `datr`, pas moins.
/// La doc en ligne range `sb` avec les indispensables — le code, non, et c'est lui
/// qui refuse la session.
final class MessengerSessionCookiesTests: XCTestCase {
  private let complete = [
    "c_user": "100012345678901",
    "xs": "42%3Aabc%3A2%3A1700000000",
    "datr": "Zxy-empreinte",
    "sb": "graine",
    "fr": "0aBc",
  ]

  func testCompleteSessionIsAccepted() throws {
    let session = try XCTUnwrap(BridgeSessionCookies(rawCookies: complete, profile: .messenger))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
  }

  /// `datr` compte autant que `xs` : sans lui le pont répond « Missing cookies »,
  /// et l'envoyer trop tôt ne ferait qu'échouer plus vite.
  func testIncompleteSessionIsRejected() {
    for missing in ["c_user", "xs", "datr"] {
      var partial = complete
      partial[missing] = nil
      XCTAssertNil(
        BridgeSessionCookies(rawCookies: partial, profile: .messenger),
        "sans \(missing), la session Messenger ne doit pas être considérée complète"
      )
    }
    var blank = complete
    blank["xs"] = ""
    XCTAssertNil(BridgeSessionCookies(rawCookies: blank, profile: .messenger))
    XCTAssertNil(BridgeSessionCookies(rawCookies: [:], profile: .messenger))
  }

  /// `sb`, `fr`, `presence`, `wd`, `oo` et `dpr` voyagent quand ils sont là, mais
  /// n'ont jamais bloqué personne : le pont les rejoue tels quels.
  func testOptionalCookiesTravelButAreNotRequired() throws {
    let minimal = try XCTUnwrap(
      BridgeSessionCookies(
        rawCookies: ["c_user": "1", "xs": "x", "datr": "d"],
        profile: .messenger
      )
    )
    XCTAssertEqual(Set(minimal.values.keys), ["c_user", "xs", "datr"])

    var withExtras = complete
    withExtras["wd"] = "1512x857"
    withExtras["presence"] = "C%7B%22t3%22"
    // Un cookie que le connecteur ne connaît pas n'a rien à faire dans la charge utile.
    withExtras["inconnu"] = "bruit"
    let full = try XCTUnwrap(BridgeSessionCookies(rawCookies: withExtras, profile: .messenger))
    XCTAssertEqual(full.values["wd"], "1512x857")
    XCTAssertNil(full.values["inconnu"])
  }

  /// La fenêtre de connexion Messenger part de facebook.com, et rien d'autre :
  /// une session Instagram croisée en route ne doit pas s'y glisser.
  func testOnlyMessengerCookiesAreKept() throws {
    var cookies = complete.map { cookie(name: $0.key, value: $0.value, domain: ".facebook.com") }
    cookies.append(cookie(name: "sessionid", value: "ig", domain: ".instagram.com"))
    cookies.append(cookie(name: "c_user", value: "autre-site", domain: ".exemple.fr"))

    let session = try XCTUnwrap(BridgeSessionCookies(httpCookies: cookies, profile: .messenger))
    XCTAssertEqual(Set(session.values.keys), Set(complete.keys))
    XCTAssertEqual(session.values["c_user"], "100012345678901")
    XCTAssertNil(session.values["sessionid"])

    XCTAssertTrue(BridgeSessionCookies.Profile.messenger.acceptsDomain("www.facebook.com"))
    XCTAssertTrue(BridgeSessionCookies.Profile.messenger.acceptsDomain(".facebook.com"))
    XCTAssertFalse(BridgeSessionCookies.Profile.messenger.acceptsDomain("faux-facebook.com"))
    // Le domaine d'un profil ne déborde pas sur celui de l'autre.
    XCTAssertFalse(BridgeSessionCookies.Profile.messenger.acceptsDomain("instagram.com"))
    XCTAssertFalse(BridgeSessionCookies.Profile.instagram.acceptsDomain("facebook.com"))
  }

  func testJSONPayloadIsSortedAndFlat() throws {
    let session = try XCTUnwrap(BridgeSessionCookies(rawCookies: complete, profile: .messenger))
    let payload = session.jsonPayload
    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
    )
    XCTAssertEqual(decoded, complete)
    XCTAssertTrue(payload.hasPrefix("{\"c_user\""))
  }

  /// Le profil suit le réseau : les réseaux qui se connectent autrement n'en ont pas,
  /// et la fenêtre de connexion web ne s'ouvre pas pour eux.
  func testProfilesAreBoundToTheirNetwork() {
    XCTAssertEqual(BridgeSessionCookies.Profile.of(.messenger)?.network, .messenger)
    XCTAssertEqual(
      BridgeSessionCookies.Profile.of(.messenger)?.loginURL.absoluteString,
      "https://www.facebook.com/login/"
    )
    XCTAssertEqual(
      BridgeSessionCookies.Profile.of(.instagram)?.loginURL.absoluteString,
      "https://www.instagram.com/accounts/login/"
    )
    XCTAssertNil(BridgeSessionCookies.Profile.of(.whatsapp))
    XCTAssertNil(BridgeSessionCookies.Profile.of(.signal))
    XCTAssertNil(BridgeSessionCookies.Profile.of(.iMessage))
    XCTAssertNil(BridgeSessionCookies.Profile.of(.selfNote))
  }

  private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
    HTTPCookie(properties: [
      .name: name, .value: value, .domain: domain, .path: "/",
    ])!
  }
}
