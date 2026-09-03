import XCTest
import CorrespondanceCore
@testable import Correspondance

/// La réponse rapide : ce qu'elle ouvre, ce vers quoi elle passe, et ce
/// qu'elle vaut quand on ne lui a jamais rien réglé.
final class QuickReplyTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "quick-reply-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private func conversation(
    id: String,
    title: String,
    unread: Int = 0,
    minutesAgo: Double = 0
  ) -> Conversation {
    Conversation(
      id: id,
      network: .signal,
      address: "adresse-\(id)",
      title: title,
      preview: "…",
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60),
      unreadCount: unread,
      isArchived: false,
      transportKey: id,
      isGroup: false
    )
  }

  // MARK: - Le fil que le panneau ouvre

  /// Ce qui attend une réponse passe avant tout le reste — et parmi les non-lus,
  /// le plus récent.
  func testDefaultThreadIsTheMostRecentUnread() {
    let queue = [
      conversation(id: "a", title: "Ancien non lu", unread: 3, minutesAgo: 120),
      conversation(id: "b", title: "Lu, tout frais", minutesAgo: 1),
      conversation(id: "c", title: "Récent non lu", unread: 1, minutesAgo: 10),
    ]
    XCTAssertEqual(
      QuickReplyQueue.defaultConversationID(in: queue, selectedID: "b"),
      "c"
    )
  }

  /// Rien de non lu : le panneau montre ce que l'inbox avait sous les yeux.
  func testDefaultThreadFallsBackToTheSelection() {
    let queue = [
      conversation(id: "a", title: "Alice", minutesAgo: 5),
      conversation(id: "b", title: "Bruno", minutesAgo: 1),
    ]
    XCTAssertEqual(QuickReplyQueue.defaultConversationID(in: queue, selectedID: "a"), "a")
  }

  /// Une sélection qui n'est plus dans la file ne vaut rien : on prend la tête.
  func testDefaultThreadIgnoresAStaleSelection() {
    let queue = [conversation(id: "a", title: "Alice"), conversation(id: "b", title: "Bruno")]
    XCTAssertEqual(QuickReplyQueue.defaultConversationID(in: queue, selectedID: "disparu"), "a")
    XCTAssertEqual(QuickReplyQueue.defaultConversationID(in: queue, selectedID: nil), "a")
  }

  /// Une file vide n'ouvre rien du tout.
  func testDefaultThreadOfAnEmptyQueueIsNothing() {
    XCTAssertNil(QuickReplyQueue.defaultConversationID(in: [], selectedID: "a"))
    XCTAssertNil(QuickReplyQueue.defaultConversationID(in: [], selectedID: nil))
  }

  // MARK: - ⌘↑ / ⌘↓

  /// La file tourne en rond : on ne se retrouve jamais au bout de rien.
  func testStepWrapsAround() {
    let ids = ["a", "b", "c"]
    XCTAssertEqual(QuickReplyQueue.step(from: "a", in: ids, by: 1), "b")
    XCTAssertEqual(QuickReplyQueue.step(from: "c", in: ids, by: 1), "a")
    XCTAssertEqual(QuickReplyQueue.step(from: "a", in: ids, by: -1), "c")
    XCTAssertEqual(QuickReplyQueue.step(from: "b", in: ids, by: -1), "a")
  }

  /// Un seul fil : ⌘↑ et ⌘↓ restent dessus plutôt que de perdre la page.
  func testStepOnASingleThreadStaysThere() {
    XCTAssertEqual(QuickReplyQueue.step(from: "a", in: ["a"], by: 1), "a")
    XCTAssertEqual(QuickReplyQueue.step(from: "a", in: ["a"], by: -1), "a")
  }

  /// Un fil disparu de la file renvoie au premier ; une file vide, à rien.
  func testStepFromAnUnknownThread() {
    XCTAssertEqual(QuickReplyQueue.step(from: "disparu", in: ["a", "b"], by: 1), "a")
    XCTAssertEqual(QuickReplyQueue.step(from: nil, in: ["a", "b"], by: -1), "a")
    XCTAssertNil(QuickReplyQueue.step(from: "a", in: [], by: 1))
  }

  // MARK: - Réglages

  /// Les valeurs d'usine : le raccourci répond, le panneau se referme derrière
  /// le message, rien ne s'installe dans la barre des menus, et le panneau
  /// suit les bureaux — y compris les plein-écran.
  func testFactorySettings() {
    XCTAssertTrue(QuickReplyPreferences.isEnabled(in: defaults))
    XCTAssertTrue(QuickReplyPreferences.closesAfterSend(in: defaults))
    XCTAssertFalse(QuickReplyPreferences.showsMenuBarExtra(in: defaults))
    XCTAssertFalse(QuickReplyPreferences.avoidsFullScreen(in: defaults))
    XCTAssertEqual(QuickReplyPreferences.hotKey(in: defaults), .controlOptionSpace)
  }

  /// Un réglage éteint à la main reste éteint — un `false` n'est pas un « jamais touché ».
  func testTurningASettingOffSticks() {
    QuickReplyPreferences.setEnabled(false, in: defaults)
    QuickReplyPreferences.setClosesAfterSend(false, in: defaults)
    XCTAssertFalse(QuickReplyPreferences.isEnabled(in: defaults))
    XCTAssertFalse(QuickReplyPreferences.closesAfterSend(in: defaults))

    QuickReplyPreferences.setShowsMenuBarExtra(true, in: defaults)
    QuickReplyPreferences.setAvoidsFullScreen(true, in: defaults)
    XCTAssertTrue(QuickReplyPreferences.showsMenuBarExtra(in: defaults))
    XCTAssertTrue(QuickReplyPreferences.avoidsFullScreen(in: defaults))
  }

  /// Un raccourci illisible dans les réglages ne casse rien : on reprend celui d'usine.
  func testUnknownHotKeyFallsBackToTheDefault() {
    defaults.set("⌘⌥Bidule", forKey: QuickReplyPreferences.hotKeyKey)
    XCTAssertEqual(QuickReplyPreferences.hotKey(in: defaults), .controlOptionSpace)

    QuickReplyPreferences.setHotKey(.controlOptionR, in: defaults)
    XCTAssertEqual(QuickReplyPreferences.hotKey(in: defaults), .controlOptionR)
  }

  /// Les quatre combinaisons sont distinctes, libellées, et parlent Carbon :
  /// 49 = Espace, 15 = R ; 4096 = ⌃, 2048 = ⌥, 512 = ⇧.
  func testHotKeyCombosSpeakCarbon() {
    XCTAssertEqual(QuickReplyHotKey.controlOptionSpace.keyCode, 49)
    XCTAssertEqual(QuickReplyHotKey.controlOptionSpace.modifiers, 4096 | 2048)
    XCTAssertEqual(QuickReplyHotKey.controlOptionR.keyCode, 15)
    XCTAssertEqual(QuickReplyHotKey.controlShiftSpace.modifiers, 4096 | 512)
    XCTAssertEqual(QuickReplyHotKey.optionSpace.modifiers, 2048)

    let signatures = QuickReplyHotKey.allCases.map { "\($0.keyCode)|\($0.modifiers)" }
    XCTAssertEqual(Set(signatures).count, QuickReplyHotKey.allCases.count)
    XCTAssertTrue(QuickReplyHotKey.allCases.allSatisfy { !$0.labelFR.isEmpty })
  }
}

/// Le panneau lui-même : ce qu'il choisit, et ce que ⌘↑ / ⌘↓ lui font faire.
@MainActor
final class QuickReplyModelTests: XCTestCase {
  private func conversation(id: String, title: String, unread: Int, minutesAgo: Double) -> Conversation {
    Conversation(
      id: id,
      network: .signal,
      address: "adresse-\(id)",
      title: title,
      preview: "Un message",
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60),
      unreadCount: unread,
      isArchived: false,
      transportKey: id,
      isGroup: false
    )
  }

  private func makeStore() -> InboxStore {
    let store = InboxStore()
    // Le magasin relit le rail réseau de l'app hôte : un rail posé sur
    // Messenger viderait la file du test. On le neutralise, et on le rend.
    let rail = store.networkFilter
    addTeardownBlock { store.networkFilter = rail }
    store.networkFilter = nil
    store.clearMergedContactsForTesting()
    store.conversations = [
      conversation(id: "sig:1", title: "Élise", unread: 0, minutesAgo: 1),
      conversation(id: "sig:2", title: "Paul", unread: 2, minutesAgo: 30),
      conversation(id: "sig:3", title: "Camille", unread: 0, minutesAgo: 90),
    ]
    return store
  }

  /// À froid, le panneau s'ouvre sur ce qui attend une réponse.
  func testPanelOpensOnTheUnreadThread() {
    let store = makeStore()
    store.selectedConversationID = "sig:1"
    let model = QuickReplyModel()
    model.openDefault(in: store)
    XCTAssertEqual(model.conversationID, "sig:2")
  }

  /// ⌘↓ puis ⌘↑ ramènent exactement où l'on était, et la file boucle.
  func testStepsGoAroundTheQueue() {
    let store = makeStore()
    let model = QuickReplyModel()
    let ids = model.queue(in: store).map(\.id)
    XCTAssertEqual(ids.count, 3)

    model.conversationID = ids[0]
    model.step(in: store, by: 1)
    XCTAssertEqual(model.conversationID, ids[1])
    model.step(in: store, by: -1)
    XCTAssertEqual(model.conversationID, ids[0])
    // Un cran en arrière depuis la tête : on arrive à la queue.
    model.step(in: store, by: -1)
    XCTAssertEqual(model.conversationID, ids[2])
    model.step(in: store, by: 1)
    XCTAssertEqual(model.conversationID, ids[0])
  }

  /// Choisir dans le mini-sélecteur ferme le sélecteur et vide sa requête.
  func testChoosingFromThePickerClosesIt() {
    let model = QuickReplyModel()
    model.togglePicker()
    model.query = "cam"
    XCTAssertTrue(model.isShowingPicker)

    model.choose("sig:3")
    XCTAssertEqual(model.conversationID, "sig:3")
    XCTAssertFalse(model.isShowingPicker)
    XCTAssertEqual(model.query, "")
  }

  /// Le panneau tient une session comme une fenêtre détachée : la même que
  /// l'inbox quand c'est le même fil, une autre sinon.
  func testPanelSharesTheThreadSession() {
    let store = makeStore()
    store.selectedConversationID = "sig:1"
    let model = QuickReplyModel()
    model.openDefault(in: store)

    let panelSession = store.session(for: model.conversationID!)
    XCTAssertFalse(panelSession === store.primarySession)
    XCTAssertTrue(panelSession === store.session(for: "sig:2"))

    model.choose("sig:1")
    XCTAssertTrue(store.session(for: model.conversationID!) === store.primarySession)
  }
}
