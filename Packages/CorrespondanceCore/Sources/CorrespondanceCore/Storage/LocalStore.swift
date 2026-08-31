import Foundation

/// Le magasin local : les conversations du Relais, leurs messages, et le
/// curseur de `/sync`, dans une base SQLite à nous.
///
/// Ce qu'il remplace : un instantané JSON global, relu en entier au lancement et
/// **réécrit en entier** à chaque passe de `/sync`. Ici une passe n'écrit que ce
/// qu'elle change, dans une transaction, et une conversation ne charge son
/// historique qu'à l'ouverture.
///
/// Synchrone et verrouillé : l'acteur du pont l'appelle sans saut de tâche, et
/// deux appelants ne se marchent pas dessus. `@unchecked Sendable` se justifie
/// par ce verrou, et par lui seul.
public final class LocalStore: @unchecked Sendable {
  let database: SQLiteDatabase
  private let lock = NSRecursiveLock()
  /// La dernière chose que SQLite a refusée. Une base qui boude ne doit jamais
  /// faire tomber l'inbox : on note, on continue, et Réglages peut le dire.
  public private(set) var lastError: Error?

  /// Le dossier de l'app — `~/Library/Application Support/Correspondance` sur
  /// Mac, le conteneur équivalent sur iPhone.
  public static func applicationSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  public static func defaultURL() -> URL {
    applicationSupportDirectory().appendingPathComponent("correspondance.sqlite")
  }

  /// L'unique base de l'app. `nil` si SQLite refuse d'ouvrir le fichier :
  /// l'inbox marche alors sans mémoire, plutôt que pas du tout.
  public static let shared: LocalStore? = try? LocalStore()

  public init(path: String) throws {
    database = try SQLiteDatabase(path: path)
    try migrate()
  }

  public convenience init() throws {
    try self.init(path: Self.defaultURL().path)
  }

  /// Une base en mémoire, pour les tests : rien à nettoyer derrière soi.
  public static func inMemory() throws -> LocalStore {
    try LocalStore(path: SQLiteDatabase.inMemoryPath)
  }

  // MARK: - Verrou

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Une écriture dont l'échec ne doit pas remonter jusqu'à l'inbox.
  func attempt(_ body: () throws -> Void) {
    withLock {
      do { try body() } catch { lastError = error }
    }
  }

  /// Une lecture qui rend `fallback` si la base refuse.
  func read<T>(_ fallback: T, _ body: () throws -> T) -> T {
    withLock {
      do { return try body() } catch {
        lastError = error
        return fallback
      }
    }
  }

  // MARK: - Schéma

  /// Version du schéma attendue par ce code. Chaque migration est jouée dans
  /// l'ordre, une fois, et la base retient où elle en est — plus de champ
  /// « absent des caches plus anciens » : la forme est la même pour tous.
  static let schemaVersion = 1

  private func migrate() throws {
    try withLock {
      try database.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);")
      let current = try database.scalarInt("SELECT MAX(version) FROM schema_version;").map(Int.init) ?? 0
      guard current < Self.schemaVersion else { return }
      try database.transaction {
        for step in (current + 1)...Self.schemaVersion {
          try database.execute(Self.migration(to: step))
          try database.run("INSERT INTO schema_version (version) VALUES (?);", [.int(Int64(step))])
        }
      }
    }
  }

  /// La version du schéma effectivement installée.
  public var installedSchemaVersion: Int {
    read(0) { try database.scalarInt("SELECT MAX(version) FROM schema_version;").map(Int.init) ?? 0 }
  }

  private static func migration(to version: Int) -> String {
    switch version {
    case 1: return schemaV1
    default: return ""
    }
  }

  /// v1 — salons, messages, réactions, curseur.
  ///
  /// `rooms` porte en colonnes tout ce que l'inbox affiche (réseau compris :
  /// une conversation rechargée sait de quel réseau elle vient **sans** le
  /// serveur) et en blob l'état du salon dont le parseur a besoin — membres,
  /// marqueurs de lecture, sondages, modifications en attente.
  ///
  /// `messages` indexe ce sur quoi on trie et filtre, et range le reste
  /// (pièces jointes, citation, aperçu de lien, sondage, vocal) dans un blob
  /// `Codable`. Ce qui se cherche a sa colonne ; ce qui s'affiche a son blob.
  private static let schemaV1 = """
  CREATE TABLE rooms (
    room_id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    network TEXT,
    title TEXT NOT NULL,
    preview TEXT NOT NULL,
    last_message_at REAL NOT NULL,
    unread_count INTEGER NOT NULL,
    transport_key TEXT NOT NULL,
    is_group INTEGER NOT NULL,
    avatar_mxc TEXT,
    member_avatar_ids TEXT NOT NULL,
    state BLOB NOT NULL
  );
  CREATE INDEX rooms_by_recency ON rooms (last_message_at DESC);

  CREATE TABLE messages (
    event_id TEXT PRIMARY KEY NOT NULL,
    room_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    sent_at REAL NOT NULL,
    sender_id TEXT,
    sender_name TEXT,
    text TEXT NOT NULL,
    is_from_me INTEGER NOT NULL,
    attachment_names TEXT NOT NULL,
    attachment_types TEXT NOT NULL,
    payload BLOB NOT NULL
  );
  CREATE INDEX messages_by_room ON messages (room_id, sent_at DESC);

  CREATE TABLE reactions (
    event_id TEXT PRIMARY KEY NOT NULL,
    room_id TEXT NOT NULL,
    target_event_id TEXT NOT NULL,
    emoji TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    sender_name TEXT NOT NULL,
    is_mine INTEGER NOT NULL
  );
  CREATE INDEX reactions_by_room ON reactions (room_id);

  CREATE TABLE sync_state (key TEXT PRIMARY KEY NOT NULL, value TEXT);
  """

  // MARK: - Curseur de `/sync`

  /// Le `next_batch` de la dernière passe **entièrement traitée et écrite**.
  public var syncCursor: String? {
    read(nil) { try database.scalarString("SELECT value FROM sync_state WHERE key = 'next_batch';") }
  }

  /// À n'appeler qu'une fois le lot écrit : un curseur avancé sur un lot perdu
  /// perd ce lot pour de bon — Synapse ne renvoie jamais deux fois la même
  /// invitation de portail.
  public func setSyncCursor(_ value: String?) {
    attempt {
      guard let value else {
        try database.run("DELETE FROM sync_state WHERE key = 'next_batch';")
        return
      }
      try database.run(
        "INSERT INTO sync_state (key, value) VALUES ('next_batch', ?) "
          + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
        [.text(value)]
      )
    }
  }

  /// Une valeur libre de `sync_state` (l'heure de la dernière réconciliation,
  /// le drapeau de migration…).
  public func flag(_ key: String) -> String? {
    read(nil) {
      try database.scalarString("SELECT value FROM sync_state WHERE key = ?;", [.text(key)])
    }
  }

  public func setFlag(_ key: String, to value: String?) {
    attempt {
      guard let value else {
        try database.run("DELETE FROM sync_state WHERE key = ?;", [.text(key)])
        return
      }
      try database.run(
        "INSERT INTO sync_state (key, value) VALUES (?, ?) "
          + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
        [.text(key), .text(value)]
      )
    }
  }

  // MARK: - Table rase

  /// « Recharger depuis le Relais » : la base se vide, le curseur repart de
  /// zéro, et le prochain `/sync` la repeuple.
  public func reset() {
    attempt {
      try database.transaction {
        try database.execute("DELETE FROM messages; DELETE FROM reactions; DELETE FROM rooms; DELETE FROM sync_state;")
      }
    }
  }
}
