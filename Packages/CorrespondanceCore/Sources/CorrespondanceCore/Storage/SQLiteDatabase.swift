import Foundation
import SQLite3

/// Ce que SQLite peut refuser, dit en français et avec la requête fautive.
public enum SQLiteError: LocalizedError, Sendable, Equatable {
  case cannotOpen(path: String, detail: String)
  case cannotPrepare(sql: String, detail: String)
  case cannotStep(sql: String, detail: String)
  case cannotBind(index: Int, detail: String)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let path, let detail):
      "Base locale illisible (\(path)) : \(detail)"
    case .cannotPrepare(let sql, let detail):
      "Requête refusée : \(detail) — \(Self.excerpt(sql))"
    case .cannotStep(let sql, let detail):
      "Écriture refusée : \(detail) — \(Self.excerpt(sql))"
    case .cannotBind(let index, let detail):
      "Paramètre \(index) refusé : \(detail)"
    }
  }

  /// Une requête entière dans un message d'erreur ne se lit pas : on garde le début.
  private static func excerpt(_ sql: String) -> String {
    let flat = sql.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
  }
}

/// Une valeur qu'on lie à un `?` d'une requête préparée.
public enum SQLiteValue: Sendable, Equatable {
  case text(String)
  case int(Int64)
  case real(Double)
  case blob(Data)
  case null

  /// Un texte absent devient `NULL`, jamais la chaîne vide : la base doit
  /// pouvoir distinguer « pas de titre » de « titre vide ».
  public static func optionalText(_ value: String?) -> SQLiteValue {
    value.map { .text($0) } ?? .null
  }

  public static func bool(_ value: Bool) -> SQLiteValue { .int(value ? 1 : 0) }

  public static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSince1970) }
}

/// Une requête préparée. Vit le temps d'un appel : pas de cache de statements
/// tant que rien ne prouve qu'il en manque un.
public final class SQLiteStatement {
  private var handle: OpaquePointer?
  private let sql: String
  private unowned let database: SQLiteDatabase
  /// `SQLITE_TRANSIENT` : SQLite recopie la valeur liée. Sans ça, une `String`
  /// Swift libérée avant le `step` laisserait un pointeur mort.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(database: SQLiteDatabase, handle: OpaquePointer, sql: String) {
    self.database = database
    self.handle = handle
    self.sql = sql
  }

  deinit { sqlite3_finalize(handle) }

  @discardableResult
  public func bind(_ values: [SQLiteValue]) throws -> SQLiteStatement {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .text(let string):
        code = string.withCString { sqlite3_bind_text(handle, index, $0, -1, Self.transient) }
      case .int(let number):
        code = sqlite3_bind_int64(handle, index, number)
      case .real(let number):
        code = sqlite3_bind_double(handle, index, number)
      case .blob(let data):
        code = data.isEmpty
          ? sqlite3_bind_zeroblob(handle, index, 0)
          : data.withUnsafeBytes {
            sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(data.count), Self.transient)
          }
      case .null:
        code = sqlite3_bind_null(handle, index)
      }
      guard code == SQLITE_OK else {
        throw SQLiteError.cannotBind(index: offset + 1, detail: database.lastErrorMessage)
      }
    }
    return self
  }

  /// `true` tant qu'une ligne se présente, `false` quand la requête est finie.
  @discardableResult
  public func step() throws -> Bool {
    switch sqlite3_step(handle) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw SQLiteError.cannotStep(sql: sql, detail: database.lastErrorMessage)
    }
  }

  /// Joue la requête jusqu'au bout sans rien lire (INSERT, UPDATE, DELETE).
  public func run() throws {
    while try step() {}
  }

  /// Parcourt les lignes ; `body` lit la ligne courante.
  public func forEachRow(_ body: (SQLiteStatement) throws -> Void) throws {
    while try step() { try body(self) }
  }

  public func isNull(_ column: Int) -> Bool {
    sqlite3_column_type(handle, Int32(column)) == SQLITE_NULL
  }

  public func string(_ column: Int) -> String {
    guard let pointer = sqlite3_column_text(handle, Int32(column)) else { return "" }
    return String(cString: pointer)
  }

  public func optionalString(_ column: Int) -> String? {
    isNull(column) ? nil : string(column)
  }

  public func int(_ column: Int) -> Int64 {
    sqlite3_column_int64(handle, Int32(column))
  }

  public func bool(_ column: Int) -> Bool { int(column) != 0 }

  public func double(_ column: Int) -> Double {
    sqlite3_column_double(handle, Int32(column))
  }

  public func date(_ column: Int) -> Date {
    Date(timeIntervalSince1970: double(column))
  }

  public func data(_ column: Int) -> Data {
    let count = Int(sqlite3_column_bytes(handle, Int32(column)))
    guard count > 0, let pointer = sqlite3_column_blob(handle, Int32(column)) else { return Data() }
    return Data(bytes: pointer, count: count)
  }
}

/// Une base SQLite ouverte, sans dépendance externe — même approche que
/// `IMessageDatabase` côté Mac, mais en écriture et portable sur iPhone.
///
/// Volontairement **synchrone** et non `Sendable` : c'est `LocalStore` qui pose
/// le verrou et se déclare partageable. Une base ne se promène pas seule d'une
/// tâche à l'autre.
public final class SQLiteDatabase {
  private var handle: OpaquePointer?
  public let path: String

  /// Base en mémoire — celle des tests. Elle disparaît avec l'objet.
  public static let inMemoryPath = ":memory:"

  public init(path: String) throws {
    self.path = path
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
      let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
      sqlite3_close(handle)
      handle = nil
      throw SQLiteError.cannotOpen(path: path, detail: detail)
    }
    // WAL : une lecture ne bloque plus une écriture. Sans effet sur `:memory:`,
    // qui refuse le mode — on ne s'en formalise pas.
    if path != Self.inMemoryPath {
      try? execute("PRAGMA journal_mode = WAL;")
    }
    // Le compromis d'usage du WAL : on ne perd rien au plantage de l'app,
    // seulement à celui de la machine — et un `/sync` le regagne.
    try execute("PRAGMA synchronous = NORMAL;")
    // Cinq secondes d'attente plutôt qu'un « database is locked » immédiat
    // si deux processus tombent dessus en même temps.
    sqlite3_busy_timeout(handle, 5_000)
  }

  deinit { sqlite3_close(handle) }

  var lastErrorMessage: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "base fermée"
  }

  public func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let detail = error.map { String(cString: $0) } ?? lastErrorMessage
      sqlite3_free(error)
      throw SQLiteError.cannotStep(sql: sql, detail: detail)
    }
  }

  public func prepare(_ sql: String) throws -> SQLiteStatement {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SQLiteError.cannotPrepare(sql: sql, detail: lastErrorMessage)
    }
    return SQLiteStatement(database: self, handle: statement, sql: sql)
  }

  /// Une requête, ses paramètres, rien à lire.
  public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
    try prepare(sql).bind(values).run()
  }

  /// La première colonne de la première ligne, en entier.
  public func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
    let statement = try prepare(sql).bind(values)
    return try statement.step() ? statement.int(0) : nil
  }

  /// La première colonne de la première ligne, en texte.
  public func scalarString(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
    let statement = try prepare(sql).bind(values)
    guard try statement.step(), !statement.isNull(0) else { return nil }
    return statement.string(0)
  }

  /// Tout ou rien. Une transaction par lot `/sync` : c'est elle qui remplace la
  /// réécriture globale du fichier JSON.
  @discardableResult
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE;")
    do {
      let result = try body()
      try execute("COMMIT;")
      return result
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  /// FTS5 est-il compilé dans ce SQLite ? Vrai sur le SQLite système de macOS
  /// et d'iOS — un test s'en assure, plutôt que de le croire sur parole.
  public var supportsFTS5: Bool {
    do {
      try execute("CREATE VIRTUAL TABLE IF NOT EXISTS fr_correspondance_fts5_probe USING fts5(x);")
      try execute("DROP TABLE IF EXISTS fr_correspondance_fts5_probe;")
      return true
    } catch {
      return false
    }
  }
}
