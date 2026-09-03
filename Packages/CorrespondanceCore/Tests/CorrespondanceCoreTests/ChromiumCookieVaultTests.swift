#if canImport(CommonCrypto)
import XCTest
@testable import CorrespondanceCore

/// Les vecteurs viennent d'ailleurs que du code testé : la clé par
/// `hashlib.pbkdf2_hmac` de Python, le chiffré par `openssl enc -aes-128-cbc`
/// avec cette clé et seize espaces d'IV, le hachage du domaine par `hashlib.sha256`.
final class ChromiumCookieVaultTests: XCTestCase {
  private let key = ChromiumCookieVault.key(fromSafeStoragePassword: "peanuts")

  func testKeyDerivationMatchesChromium() {
    XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "d9a09d499b4e1b7461f28e67972c6dbd")
  }

  /// Un cookie d'avant Chromium 130 : pas de hachage en tête.
  func testDecryptsALegacyValue() {
    let encrypted = Data(hex: "76313037ef73793a7058d71f6974905a6cdc09")
    XCTAssertEqual(ChromiumCookieVault.decrypt(encrypted, key: key, hostKey: ".x.com"), "abc123token")
  }

  /// Un cookie d'aujourd'hui : SHA-256 de `.x.com` devant la valeur, retiré.
  func testDecryptsAValuePrefixedWithTheDomainHash() {
    let encrypted = Data(hex: "763130e90e999aff5aec3a49e121d2d9a164bbe042c1aa3fbc49372056485767de539dfe89f8b47372bfd99e199d8c14c3c82b")
    XCTAssertEqual(ChromiumCookieVault.decrypt(encrypted, key: key, hostKey: ".x.com"), "abc123token")
  }

  /// Le mauvais domaine ne fait pas mentir : le hachage ne correspond pas, il
  /// reste dans la valeur, qui n'est plus de l'UTF-8 lisible — ou le serait par
  /// hasard, mais jamais « abc123token ».
  func testTheWrongHostKeyDoesNotStripTheHash() {
    let encrypted = Data(hex: "763130e90e999aff5aec3a49e121d2d9a164bbe042c1aa3fbc49372056485767de539dfe89f8b47372bfd99e199d8c14c3c82b")
    XCTAssertNotEqual(ChromiumCookieVault.decrypt(encrypted, key: key, hostKey: ".exemple.fr"), "abc123token")
  }

  func testRefusesWhatIsNotAV10Value() {
    XCTAssertNil(ChromiumCookieVault.decrypt(Data("v11abcdefghijklmnop".utf8), key: key, hostKey: ".x.com"))
    XCTAssertNil(ChromiumCookieVault.decrypt(Data("v10".utf8), key: key, hostKey: ".x.com"))
    XCTAssertNil(ChromiumCookieVault.decrypt(Data(), key: key, hostKey: ".x.com"))
    // Une autre clé ne déchiffre pas : le bourrage PKCS#7 ne tombe pas juste.
    let other = ChromiumCookieVault.key(fromSafeStoragePassword: "autre")
    XCTAssertNil(ChromiumCookieVault.decrypt(Data(hex: "76313037ef73793a7058d71f6974905a6cdc09"), key: other, hostKey: ".x.com"))
  }
}

private extension Data {
  init(hex: String) {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }
}
#endif
