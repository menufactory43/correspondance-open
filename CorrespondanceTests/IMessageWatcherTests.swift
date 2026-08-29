import XCTest
@testable import Correspondance

/// Surveillance du journal WAL de chat.db, exercée sur des fichiers temporaires.
final class IMessageWatcherTests: XCTestCase {
  private var directory: URL!
  private var databaseURL: URL!
  private var walURL: URL!
  private var watcher: IMessageWatcher?

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("correspondance-watcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appendingPathComponent("chat.db")
    walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    try Data("db".utf8).write(to: databaseURL)
  }

  override func tearDown() {
    watcher?.stop()
    watcher = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private static func append(_ text: String, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
    } else {
      try Data(text.utf8).write(to: url)
    }
  }

  /// Une écriture dans le WAL déclenche bien un rafraîchissement.
  func testWriteToTheWALTriggersARefresh() throws {
    try Data("wal".utf8).write(to: walURL)
    let fired = expectation(description: "rafraîchissement déclenché")
    fired.assertForOverFulfill = false

    let watcher = IMessageWatcher(databaseURL: databaseURL, debounce: .milliseconds(50))
    self.watcher = watcher
    XCTAssertTrue(watcher.start { fired.fulfill() })

    try Self.append("x", to: walURL)
    wait(for: [fired], timeout: 5)
  }

  /// Messages écrit plusieurs fois par message reçu : le debounce doit coalescer.
  func testBurstOfWritesIsCoalescedIntoOneRefresh() throws {
    try Data("wal".utf8).write(to: walURL)
    let counter = Counter()
    let fired = expectation(description: "rafraîchissement déclenché")
    fired.assertForOverFulfill = false

    let watcher = IMessageWatcher(databaseURL: databaseURL, debounce: .milliseconds(300))
    self.watcher = watcher
    XCTAssertTrue(watcher.start {
      await counter.increment()
      fired.fulfill()
    })

    for index in 0..<8 {
      try Self.append("écriture \(index)", to: walURL)
    }
    wait(for: [fired], timeout: 5)
    // Laisse passer une fenêtre complète avant de compter.
    let settled = expectation(description: "fenêtre écoulée")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
    wait(for: [settled], timeout: 3)

    let count = runBlocking { await counter.value }
    XCTAssertEqual(count, 1, "une rafale d'écritures doit donner un seul rafraîchissement")
  }

  /// Sans WAL, on surveille la base elle-même — sinon rien ne démarrerait au lancement.
  func testWatcherStartsOnTheDatabaseWhenNoWALExists() throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
    let watcher = IMessageWatcher(databaseURL: databaseURL, debounce: .milliseconds(50))
    self.watcher = watcher
    XCTAssertTrue(watcher.start {})
  }

  /// Aucun fichier lisible (accès disque refusé) : `start` doit le dire.
  func testWatcherReportsFailureWhenNothingIsReadable() {
    let missing = directory.appendingPathComponent("absent.db")
    let watcher = IMessageWatcher(databaseURL: missing, debounce: .milliseconds(50))
    self.watcher = watcher
    XCTAssertFalse(watcher.start {})
  }

  /// Un point de contrôle SQLite recrée le WAL : la surveillance doit se ré-armer,
  /// sans quoi elle s'arrêterait en silence au bout de quelques minutes.
  func testWatcherRearmsAfterTheWALIsRecreated() throws {
    try Data("wal".utf8).write(to: walURL)
    let afterCheckpoint = expectation(description: "écriture post-checkpoint vue")
    afterCheckpoint.assertForOverFulfill = false
    let counter = Counter()

    let watcher = IMessageWatcher(databaseURL: databaseURL, debounce: .milliseconds(50))
    self.watcher = watcher
    XCTAssertTrue(watcher.start {
      if await counter.increment() >= 2 { afterCheckpoint.fulfill() }
    })

    // Point de contrôle : le WAL est supprimé puis recréé.
    let wal = walURL!
    try FileManager.default.removeItem(at: wal)
    let recreated = expectation(description: "WAL recréé")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      try? Data("neuf".utf8).write(to: wal)
      recreated.fulfill()
    }
    wait(for: [recreated], timeout: 3)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      try? Self.append("après checkpoint", to: wal)
    }
    wait(for: [afterCheckpoint], timeout: 6)
  }

  // MARK: - Outils

  private actor Counter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int {
      value += 1
      return value
    }
  }

  private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T>()
    Task {
      box.value = await work()
      semaphore.signal()
    }
    semaphore.wait()
    return box.value!
  }

  private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T?
  }
}
