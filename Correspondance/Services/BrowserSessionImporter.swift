import AppKit
import Foundation
import SQLite3
import Security
import CorrespondanceCore

/// Un navigateur Chromium installé sur ce Mac, avec ce qu'il faut pour y lire une session.
struct InstalledBrowser: Identifiable, Hashable {
  let id: String
  /// Ce que l'utilisateur lit : « Brave », « Chrome ».
  let name: String
  /// L'entrée du Trousseau qui garde la clé des cookies : « Brave Safe Storage ».
  let keychainService: String
  /// Le dossier des profils, sous ~/Library/Application Support.
  let profilesRoot: URL
}

/// Lire la session d'un réseau là où elle est déjà : dans le navigateur de la machine.
///
/// C'est ce que Beeper appelle `browser-session-import`, et la seule façon de
/// connecter un compte protégé par une passkey — une WKWebView ne sait pas en
/// ouvrir une, Brave si. Le chemin : copier le fichier `Cookies` du profil (SQLite,
/// verrouillé pendant que le navigateur tourne), demander au Trousseau la clé du
/// navigateur — macOS affiche alors sa boîte « Correspondance veut accéder à … »,
/// et c'est l'utilisateur qui dit oui —, déchiffrer les seuls cookies que le pont
/// attend, et les rendre. Rien n'est écrit, rien n'est journalisé, la copie du
/// fichier est détruite avant de rendre la main.
///
/// Le déchiffrement lui-même (`ChromiumCookieVault`) vit dans le cœur, testé sans
/// navigateur ; ici il n'y a que le disque et le Trousseau.
enum BrowserSessionImporter {
  enum ImportError: LocalizedError {
    case keychainRefused(String)
    case keychainMissing(String)
    case noSession(browser: String, site: String)
    case unreadable(String)

    var errorDescription: String? {
      switch self {
      case .keychainRefused(let name):
        "Sans l’accord du Trousseau, la session de \(name) reste illisible."
      case .keychainMissing(let name):
        "\(name) n’a pas encore de clé dans le Trousseau : ouvre-le une fois, puis réessaie."
      case .noSession(let browser, let site):
        "Aucune session \(site) dans \(browser) : connecte-toi d’abord sur \(site) dans \(browser)."
      case .unreadable(let detail):
        "Les cookies du navigateur n’ont pas pu être lus : \(detail)"
      }
    }
  }

  private static let candidates: [(id: String, name: String, service: String, path: String)] = [
    ("brave", "Brave", "Brave Safe Storage", "BraveSoftware/Brave-Browser"),
    ("chrome", "Chrome", "Chrome Safe Storage", "Google/Chrome"),
    ("edge", "Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
    ("arc", "Arc", "Arc Safe Storage", "Arc/User Data"),
    ("chromium", "Chromium", "Chromium Safe Storage", "Chromium"),
  ]

  /// Les navigateurs qui ont au moins un profil avec un fichier de cookies.
  static func installed() -> [InstalledBrowser] {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return candidates.compactMap { candidate in
      let root = support.appendingPathComponent(candidate.path, isDirectory: true)
      guard !cookieFiles(under: root).isEmpty else { return nil }
      return InstalledBrowser(
        id: candidate.id, name: candidate.name, keychainService: candidate.service, profilesRoot: root
      )
    }
  }

  /// La session complète d'un réseau, telle que le pont l'attend — ou une erreur
  /// qui dit quoi faire. À appeler hors du fil principal : la boîte du Trousseau bloque.
  static func importSession(
    from browser: InstalledBrowser,
    profile: BridgeSessionCookies.Profile
  ) throws -> [String: String] {
    let files = cookieFiles(under: browser.profilesRoot)
    guard !files.isEmpty else { throw ImportError.noSession(browser: browser.name, site: profile.cookieDomain) }
    let password = try safeStoragePassword(service: browser.keychainService, browserName: browser.name)
    let key = ChromiumCookieVault.key(fromSafeStoragePassword: password)

    // Plusieurs profils peuvent porter une session du même site : on garde celle
    // qui est complète et la plus récemment utilisée.
    var best: (values: [String: String], lastAccess: Int64)?
    for file in files {
      guard let found = try? readCookies(at: file, domain: profile.cookieDomain, key: key) else { continue }
      let raw = Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0.value.value) })
      guard let session = BridgeSessionCookies(rawCookies: raw, profile: profile) else { continue }
      let lastAccess = found.values.map(\.lastAccess).max() ?? 0
      if best == nil || lastAccess > best!.lastAccess {
        best = (session.values, lastAccess)
      }
    }
    guard let best else { throw ImportError.noSession(browser: browser.name, site: profile.cookieDomain) }
    return best.values
  }

  // MARK: - Le disque

  private static func cookieFiles(under root: URL) -> [URL] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.compactMap { dir in
      let cookies = dir.appendingPathComponent("Cookies")
      return FileManager.default.fileExists(atPath: cookies.path) ? cookies : nil
    }
  }

  private struct FoundCookie {
    let value: String
    let lastAccess: Int64
  }

  /// Les cookies du domaine, déchiffrés, le plus récent par nom.
  private static func readCookies(at file: URL, domain: String, key: Data) throws -> [String: FoundCookie] {
    // Le navigateur tient le fichier ouvert : on lit une copie, jetée ensuite.
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent("correspondance-cookies-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: file, to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }

    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      throw ImportError.unreadable("ouverture SQLite impossible")
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT host_key, name, encrypted_value, value, last_access_utc FROM cookies
      WHERE host_key = ?1 OR host_key = ?2 OR host_key LIKE ?3
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw ImportError.unreadable("table des cookies inconnue")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, domain, -1, transient)
    sqlite3_bind_text(statement, 2, ".\(domain)", -1, transient)
    sqlite3_bind_text(statement, 3, "%.\(domain)", -1, transient)

    var out: [String: FoundCookie] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let hostKey = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
            let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) })
      else { continue }
      let lastAccess = sqlite3_column_int64(statement, 4)
      var value: String?
      let length = Int(sqlite3_column_bytes(statement, 2))
      if length > 0, let bytes = sqlite3_column_blob(statement, 2) {
        value = ChromiumCookieVault.decrypt(Data(bytes: bytes, count: length), key: key, hostKey: hostKey)
      } else if let plain = sqlite3_column_text(statement, 3) {
        value = String(cString: plain)
      }
      guard let value, !value.isEmpty else { continue }
      if let known = out[name], known.lastAccess >= lastAccess { continue }
      out[name] = FoundCookie(value: value, lastAccess: lastAccess)
    }
    return out
  }

  // MARK: - Le Trousseau

  private static func safeStoragePassword(service: String, browserName: String) throws -> String {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
        throw ImportError.unreadable("clé du Trousseau illisible")
      }
      return password
    case errSecItemNotFound:
      throw ImportError.keychainMissing(browserName)
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      throw ImportError.keychainRefused(browserName)
    default:
      throw ImportError.unreadable("Trousseau : erreur \(status)")
    }
  }
}
