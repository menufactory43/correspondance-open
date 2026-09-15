import XCTest
@testable import CorrespondanceCore

/// Règles de notification : muet, fil ouvert, message de moi, doublons.
final class NotificationPolicyTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_756_400_000)

  private func conversation(
    id: String = "signal:+33600000000",
    preview: String = "On se voit demain ?",
    at offset: TimeInterval = 0,
    fromMe: Bool = false,
    archived: Bool = false
  ) -> Conversation {
    var c = Conversation(
      id: id,
      network: .signal,
      address: "+33600000000",
      title: "Alice",
      preview: preview,
      lastMessageAt: base.addingTimeInterval(offset),
      unreadCount: 1,
      isArchived: archived,
      transportKey: "+33600000000",
      isGroup: false
    )
    c.lastMessageIsFromMe = fromMe
    return c
  }

  private func decide(
    current: Conversation,
    previous: Conversation?,
    isMuted: Bool = false,
    isSelected: Bool = false,
    alreadyNotifiedAt: Date? = nil
  ) -> Bool {
    NotificationPolicy.shouldNotify(
      current: current,
      previous: previous,
      isMuted: isMuted,
      isSelected: isSelected,
      alreadyNotifiedAt: alreadyNotifiedAt,
      // « Maintenant » : deux minutes après le message le plus récent des tests.
      now: base.addingTimeInterval(180)
    )
  }

  /// Un pont qui rapatrie l'historique d'un compte fraîchement connecté verse
  /// les messages un par un, avec leur date d'origine : chacun faisait bouger
  /// le fil, donc une bannière, pour un message de trois semaines. Vieux de
  /// plus de dix minutes à l'arrivée, un message ne sonne pas.
  func testBackfilledHistoryDoesNotNotify() {
    let now = base.addingTimeInterval(30 * 24 * 3600)
    XCTAssertFalse(NotificationPolicy.shouldNotify(
      current: conversation(at: 60), previous: conversation(at: 0),
      isMuted: false, isSelected: false, alreadyNotifiedAt: nil, now: now
    ))
    // Juste sous la limite : un Relais qui rattrape un `/sync` en retard.
    XCTAssertTrue(NotificationPolicy.shouldNotify(
      current: conversation(at: 60), previous: conversation(at: 0),
      isMuted: false, isSelected: false, alreadyNotifiedAt: nil,
      now: base.addingTimeInterval(60 + NotificationPolicy.maxAge - 1)
    ))
    XCTAssertFalse(NotificationPolicy.shouldNotify(
      current: conversation(at: 60), previous: conversation(at: 0),
      isMuted: false, isSelected: false, alreadyNotifiedAt: nil,
      now: base.addingTimeInterval(60 + NotificationPolicy.maxAge + 1)
    ))
  }

  func testNewIncomingMessageNotifies() {
    XCTAssertTrue(decide(current: conversation(at: 60), previous: conversation(at: 0)))
  }

  func testMutedConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: conversation(at: 0), isMuted: true))
  }

  /// Muet veut dire « plus de notifications », pas « plus rien » : être nommé,
  /// ou se voir répondre, passe outre la sourdine.
  func testMutedConversationStillNotifiesWhenItNamesMe() {
    var current = conversation(at: 60)
    current.lastMessageIsPersonal = true
    XCTAssertTrue(decide(current: current, previous: conversation(at: 0), isMuted: true))
  }

  /// Et ce passe-droit ne lève aucune des autres règles : un fil archivé, un
  /// message de moi ou un fil sous les yeux ne sonnent pas davantage.
  func testPersonalDoesNotOverrideTheOtherRules() {
    var archived = conversation(at: 60)
    archived.lastMessageIsPersonal = true
    archived.isArchived = true
    XCTAssertFalse(decide(current: archived, previous: conversation(at: 0), isMuted: true))

    var mine = conversation(at: 60, fromMe: true)
    mine.lastMessageIsPersonal = true
    XCTAssertFalse(decide(current: mine, previous: conversation(at: 0), isMuted: true))

    var open = conversation(at: 60)
    open.lastMessageIsPersonal = true
    XCTAssertFalse(
      decide(current: open, previous: conversation(at: 0), isMuted: true, isSelected: true))
  }

  func testOpenConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: conversation(at: 0), isSelected: true))
  }

  func testMyOwnMessageNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60, fromMe: true), previous: conversation(at: 0)))
  }

  func testArchivedConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60, archived: true), previous: conversation(at: 0)))
  }

  /// Une simple resynchronisation (même horodatage) ne doit pas re-sonner.
  func testUnchangedTimestampDoesNotNotify() {
    XCTAssertFalse(decide(current: conversation(at: 0), previous: conversation(at: 0)))
  }

  /// Le même message déjà notifié ne sonne pas deux fois, même si l'état d'avant a été perdu.
  func testAlreadyNotifiedMessageDoesNotNotifyTwice() {
    XCTAssertFalse(
      decide(
        current: conversation(at: 60),
        previous: conversation(at: 0),
        alreadyNotifiedAt: base.addingTimeInterval(60)
      )
    )
  }

  /// Un fil qui apparaît (première sync, backfill) ne déclenche pas d'avalanche.
  func testBrandNewConversationDoesNotNotify() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: nil))
  }

  /// Un aperçu « catalogue » n'est pas un message reçu.
  func testPlaceholderPreviewDoesNotNotify() {
    XCTAssertFalse(
      decide(current: conversation(preview: "Écrire sur Signal…", at: 60), previous: conversation(at: 0))
    )
  }
}
