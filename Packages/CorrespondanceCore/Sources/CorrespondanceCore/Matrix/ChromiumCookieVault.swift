import Foundation
#if canImport(CommonCrypto)
import CommonCrypto

/// Le coffre des cookies d'un navigateur Chromium sur macOS — Brave, Chrome, Edge,
/// Arc —, ouvert avec la clé que le navigateur range dans le Trousseau.
///
/// C'est ce que fait Beeper (`browser-session-import`) pour connecter X ou Meta
/// sans copier-coller : lire la session là où elle est déjà. Le format est
/// celui de Chromium sur macOS, stable depuis 2013 et documenté par son code
/// (`components/os_crypt/sync/os_crypt_mac.mm`) :
///
/// - la clé : PBKDF2-HMAC-SHA1 du mot de passe « <Navigateur> Safe Storage » du
///   Trousseau, sel `saltysalt`, 1003 tours, 16 octets ;
/// - la valeur : préfixe `v10`, puis AES-128-CBC, IV de seize espaces, bourrage PKCS#7 ;
/// - depuis Chromium 130 (octobre 2024), le clair commence par le SHA-256 du
///   `host_key` du cookie (32 octets), qu'on vérifie et qu'on retire. Les
///   cookies posés avant n'en ont pas : on accepte les deux.
///
/// Rien ici ne touche au disque ni au Trousseau : ce fichier ne fait que des
/// mathématiques sur des octets qu'on lui donne, et se teste sans navigateur.
/// Lire le fichier `Cookies` et demander la clé, c'est l'affaire de l'app.
public enum ChromiumCookieVault {
  public static let versionPrefix = Data("v10".utf8)
  private static let salt = Data("saltysalt".utf8)
  private static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

  /// La clé AES dérivée du mot de passe du Trousseau.
  public static func key(fromSafeStoragePassword password: String) -> Data {
    var derived = Data(count: kCCKeySizeAES128)
    let passwordBytes = Array(password.utf8)
    let saltBytes = [UInt8](salt)
    let status = derived.withUnsafeMutableBytes { out -> Int32 in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
        saltBytes, saltBytes.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
        1003,
        out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
      )
    }
    precondition(status == kCCSuccess, "PBKDF2 a échoué : \(status)")
    return derived
  }

  /// Le cookie en clair, ou `nil` si ce n'est pas un `v10` lisible avec cette clé.
  ///
  /// `hostKey` est la colonne `host_key` de la table (`.x.com`) : c'est elle que
  /// Chromium hache en tête du clair depuis la version 130.
  public static func decrypt(_ encrypted: Data, key: Data, hostKey: String) -> String? {
    guard encrypted.count > versionPrefix.count,
          encrypted.prefix(versionPrefix.count) == versionPrefix
    else { return nil }
    let body = encrypted.dropFirst(versionPrefix.count)
    guard body.count % kCCBlockSizeAES128 == 0, !body.isEmpty else { return nil }

    var plain = Data(count: body.count + kCCBlockSizeAES128)
    var written = 0
    let status = plain.withUnsafeMutableBytes { out in
      body.withUnsafeBytes { input in
        key.withUnsafeBytes { keyBytes in
          iv.withUnsafeBytes { ivBytes in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress, key.count,
              ivBytes.baseAddress,
              input.baseAddress, body.count,
              out.baseAddress, out.count,
              &written
            )
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    plain.count = written

    // Chromium ≥ 130 : SHA-256 du domaine en tête. Un cookie plus ancien n'en a pas,
    // et une session X ou Meta est toujours plus longue que 32 octets — on ne
    // confond pas un clair court avec un hachage.
    let digest = Data(SHA256Digest.hash(Data(hostKey.utf8)))
    if plain.count >= digest.count, plain.prefix(digest.count) == digest {
      plain = plain.dropFirst(digest.count)
    }
    return String(data: plain, encoding: .utf8)
  }
}

/// SHA-256 par CommonCrypto : de quoi ne pas tirer CryptoKit ici pour un seul hachage.
enum SHA256Digest {
  static func hash(_ data: Data) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
      _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &out)
    }
    return out
  }
}
#endif
