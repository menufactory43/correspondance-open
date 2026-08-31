import XCTest
@testable import CorrespondanceCore

/// Un rappel range une conversation jusqu'à une heure — et la rend avant si
/// l'autre a parlé. Tout se joue sur une horloge fournie : rien n'attend ici.
final class ConversationReminderTests: XCTestCase {
  private let midi = Date(timeIntervalSince1970: 1_800_000_000)

  private func conversation(
    id: String = "whatsapp:!a:relais",
    lastMessageAt: Date,
    fromMe: Bool = false
  ) -> Conversation {
    Conversation(
      id: id,
      network: .whatsapp,
      address: "+33612345678",
      title: "Alice",
      preview: "Bonjour",
      lastMessageAt: lastMessageAt,
      unreadCount: 0,
      isArchived: false,
      transportKey: "!a:relais",
      isGroup: false,
      lastMessageIsFromMe: fromMe
    )
  }

  func testUneConversationDeCoteDortJusquALHeureDite() {
    let rappel = ConversationReminder(wakeAt: midi.addingTimeInterval(3_600), setAt: midi)
    XCTAssertTrue(rappel.isAsleep(now: midi.addingTimeInterval(60), lastMessageAt: midi.addingTimeInterval(-10), lastMessageIsFromMe: false))
    XCTAssertFalse(rappel.isAsleep(now: midi.addingTimeInterval(3_600), lastMessageAt: midi.addingTimeInterval(-10), lastMessageIsFromMe: false))
  }

  func testUneReponseRecueReveilleLaConversationAvantLHeure() {
    let rappel = ConversationReminder(wakeAt: midi.addingTimeInterval(86_400), setAt: midi)
    XCTAssertFalse(
      rappel.isAsleep(now: midi.addingTimeInterval(120), lastMessageAt: midi.addingTimeInterval(60), lastMessageIsFromMe: false),
      "Un message reçu après la mise de côté rend la conversation à la file."
    )
  }

  func testMonPropreMessageNeReveilleRien() {
    let rappel = ConversationReminder(wakeAt: midi.addingTimeInterval(86_400), setAt: midi)
    XCTAssertTrue(
      rappel.isAsleep(now: midi.addingTimeInterval(120), lastMessageAt: midi.addingTimeInterval(60), lastMessageIsFromMe: true),
      "Poser un rappel puis écrire un mot, c'est toujours attendre la réponse."
    )
  }

  // MARK: - Le corps écrit dans le Relais

  func testLeRappelFaitLAllerRetourParLAccountData() throws {
    let rappel = ConversationReminder(wakeAt: midi.addingTimeInterval(7_200), setAt: midi)
    let contenu = ConversationStateCodec.reminderContent(rappel)
    XCTAssertEqual(contenu.double(at: "wake_at"), rappel.wakeAt.timeIntervalSince1970 * 1000)
    let relu = try XCTUnwrap(ConversationStateCodec.reminder(in: contenu))
    XCTAssertEqual(relu.wakeAt.timeIntervalSince1970, rappel.wakeAt.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(relu.setAt.timeIntervalSince1970, rappel.setAt.timeIntervalSince1970, accuracy: 0.001)
  }

  func testUnCorpsVideLeveLeRappel() {
    XCTAssertNil(ConversationStateCodec.reminder(in: ConversationStateCodec.reminderContent(nil)))
  }

  func testLeSyncInstalleEtLeveLeRappel() throws {
    let salon = "!a:relais"
    let pose = """
    {"next_batch":"s2","rooms":{"join":{"\(salon)":{"account_data":{"events":[
      {"type":"fr.correspondance.reminder","content":{"wake_at":1800003600000,"set_at":1800000000000}}
    ]}}}}}
    """
    var instantane = ConversationStateSnapshot()
    instantane.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(pose.utf8)))
    XCTAssertEqual(instantane.reminders[salon]?.wakeAt, Date(timeIntervalSince1970: 1_800_003_600))

    let leve = """
    {"next_batch":"s3","rooms":{"join":{"\(salon)":{"account_data":{"events":[
      {"type":"fr.correspondance.reminder","content":{}}
    ]}}}}}
    """
    instantane.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(leve.utf8)))
    XCTAssertTrue(instantane.reminders.isEmpty)
  }

  // MARK: - La file

  func testUneConversationEnRappelQuitteLaFileEtLeFocus() {
    let fil = conversation(lastMessageAt: midi.addingTimeInterval(-60))
    var etat = InboxState()
    etat.reminders[fil.id] = ConversationReminder(wakeAt: midi.addingTimeInterval(3_600), setAt: midi)

    let file = InboxOrdering.list([fil], scope: .inbox, network: nil, filter: .all, state: etat, now: midi)
    XCTAssertTrue(file.isEmpty)
    XCTAssertTrue(InboxOrdering.focusQueue([fil], state: etat, now: midi).isEmpty)

    let rappels = InboxOrdering.list([fil], scope: .reminders, network: nil, filter: .all, state: etat, now: midi)
    XCTAssertEqual(rappels.map(\.id), [fil.id])
  }

  func testLHeureVenueLaConversationRevientDansLaFile() {
    let fil = conversation(lastMessageAt: midi.addingTimeInterval(-60))
    var etat = InboxState()
    etat.reminders[fil.id] = ConversationReminder(wakeAt: midi.addingTimeInterval(3_600), setAt: midi)
    let plusTard = midi.addingTimeInterval(3_601)

    XCTAssertEqual(
      InboxOrdering.list([fil], scope: .inbox, network: nil, filter: .all, state: etat, now: plusTard).map(\.id),
      [fil.id]
    )
    XCTAssertTrue(
      InboxOrdering.list([fil], scope: .reminders, network: nil, filter: .all, state: etat, now: plusTard).isEmpty
    )
  }

  func testLesRappelsSeListentDansLOrdreOuIlsSonnent() {
    let tot = conversation(id: "whatsapp:!tot:relais", lastMessageAt: midi.addingTimeInterval(-600))
    let tard = conversation(id: "whatsapp:!tard:relais", lastMessageAt: midi.addingTimeInterval(-10))
    var etat = InboxState()
    etat.reminders[tard.id] = ConversationReminder(wakeAt: midi.addingTimeInterval(7_200), setAt: midi)
    etat.reminders[tot.id] = ConversationReminder(wakeAt: midi.addingTimeInterval(3_600), setAt: midi)

    let liste = InboxOrdering.list([tard, tot], scope: .reminders, network: nil, filter: .all, state: etat, now: midi)
    XCTAssertEqual(liste.map(\.id), [tot.id, tard.id])
  }

  func testUneEcritureNonPartiePrimeSurLeRelais() {
    var file = RelayWriteQueue()
    let rappel = ConversationReminder(wakeAt: midi.addingTimeInterval(3_600), setAt: midi)
    file.enqueue(.reminder(roomID: "!a:relais", value: rappel))
    XCTAssertEqual(file.applied(to: ConversationStateSnapshot()).reminders["!a:relais"], rappel)

    // Lever le rappel avant que le premier soit parti ne fait qu'une écriture.
    file.enqueue(.reminder(roomID: "!a:relais", value: nil))
    XCTAssertEqual(file.count, 1)
    XCTAssertTrue(file.applied(to: ConversationStateSnapshot()).reminders.isEmpty)
  }
}
