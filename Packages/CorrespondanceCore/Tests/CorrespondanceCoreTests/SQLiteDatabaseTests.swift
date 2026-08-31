import XCTest
@testable import CorrespondanceCore

/// Le socle : si le wrapper ment sur une liaison ou avale une erreur, tout ce
/// qui est bâti dessus ment aussi.
final class SQLiteDatabaseTests: XCTestCase {
  private func makeDatabase() throws -> SQLiteDatabase {
    try SQLiteDatabase(path: SQLiteDatabase.inMemoryPath)
  }

  func testRoundTripsEveryValueKind() throws {
    let db = try makeDatabase()
    try db.execute("CREATE TABLE t (a TEXT, b INTEGER, c REAL, d BLOB, e TEXT);")
    try db.run(
      "INSERT INTO t VALUES (?, ?, ?, ?, ?);",
      [.text("Où ça ?"), .int(42), .real(1.5), .blob(Data([0, 1, 2])), .null]
    )
    let row = try db.prepare("SELECT a, b, c, d, e FROM t;")
    XCTAssertTrue(try row.step())
    XCTAssertEqual(row.string(0), "Où ça ?")
    XCTAssertEqual(row.int(1), 42)
    XCTAssertEqual(row.double(2), 1.5)
    XCTAssertEqual(row.data(3), Data([0, 1, 2]))
    XCTAssertNil(row.optionalString(4))
    XCTAssertFalse(try row.step())
  }

  func testTransactionRollsBackOnFailure() throws {
    let db = try makeDatabase()
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY);")
    struct Interruption: Error {}
    XCTAssertThrowsError(
      try db.transaction {
        try db.run("INSERT INTO t VALUES (1);")
        throw Interruption()
      }
    )
    XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM t;"), 0)
    // Et la base reste utilisable : le ROLLBACK a bien eu lieu.
    try db.transaction { try db.run("INSERT INTO t VALUES (2);") }
    XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM t;"), 1)
  }

  func testBadSQLThrowsInsteadOfFailingSilently() throws {
    let db = try makeDatabase()
    XCTAssertThrowsError(try db.prepare("SELECT * FROM table_qui_nexiste_pas;")) { error in
      guard case SQLiteError.cannotPrepare = error else {
        return XCTFail("erreur inattendue : \(error)")
      }
    }
  }

  /// Le SQLite système de macOS et d'iOS embarque FTS5 — la recherche du
  /// magasin local en dépend, donc on le prouve au lieu de l'espérer.
  func testSystemSQLiteHasFTS5() throws {
    XCTAssertTrue(try makeDatabase().supportsFTS5)
  }

  func testWALIsEnabledOnAFileDatabase() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wal-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try SQLiteDatabase(path: url.path)
    XCTAssertEqual(try db.scalarString("PRAGMA journal_mode;")?.lowercased(), "wal")
  }
}
