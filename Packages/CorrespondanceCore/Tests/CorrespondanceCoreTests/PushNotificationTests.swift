import XCTest
@testable import CorrespondanceCore

/// Ce que l'extension de notification affiche, et ce qu'elle refuse d'afficher.
final class PushNotificationTests: XCTestCase {
  // MARK: - Lecture de la charge utile

  func testReferenceIsReadFromASygnalPayload() {
    let payload: [String: Any] = [
      "aps": ["alert": ["loc-key": "SINGLE_UNREAD"], "mutable-content": 1],
      "room_id": "!dm-alice:correspondance.local",
      "event_id": "$msg-alice-1",
    ]
    let reference = PushNotification.reference(in: payload)
    XCTAssertEqual(reference?.roomID, "!dm-alice:correspondance.local")
    XCTAssertEqual(reference?.eventID, "$msg-alice-1")
  }

  /// Un push sans référence n'a rien à nous apprendre — le repli s'affiche.
  func testPayloadWithoutReferenceYieldsNothing() {
    XCTAssertNil(PushNotification.reference(in: ["aps": ["alert": "coucou"]]))
    XCTAssertNil(PushNotification.reference(in: ["room_id": "!x:s"]))
    XCTAssertNil(PushNotification.reference(in: ["room_id": "", "event_id": "$e"]))
  }

  // MARK: - Le texte

  func testPresentationNamesThePersonAndTheNetwork() {
    let shown = PushNotification.presentation(
      senderName: "Alice Martin",
      conversationTitle: "Alice",
      network: .whatsapp,
      text: "On se voit demain ?"
    )
    XCTAssertEqual(shown.title, "Alice Martin · WhatsApp")
    XCTAssertEqual(shown.body, "On se voit demain ?")
    XCTAssertEqual(shown.line, "Alice Martin · WhatsApp : On se voit demain ?")
  }

  /// Sans nom d'auteur — un DM bridgé n'en donne pas toujours — le titre du fil
  /// désigne la même personne.
  func testMissingSenderFallsBackToTheThreadTitle() {
    let shown = PushNotification.presentation(
      senderName: "   ",
      conversationTitle: "Alice",
      network: .signal,
      text: "Je confirme."
    )
    XCTAssertEqual(shown.title, "Alice · Signal")
  }

  /// L'événement n'a pas pu être lu : on ne devine pas, on ne ment pas.
  func testUnreadableEventShowsThePlainFallback() {
    let shown = PushNotification.presentation(
      senderName: nil,
      conversationTitle: nil,
      network: nil,
      text: nil
    )
    XCTAssertEqual(shown.title, "Correspondance")
    XCTAssertEqual(shown.body, "Nouveau message")
  }

  /// Un message sans corps (photo nue) garde le nom et prend le repli en corps —
  /// jamais une bulle blanche sur l'écran verrouillé.
  func testEmptyBodyKeepsTheNameAndTakesTheFallbackBody() {
    let shown = PushNotification.presentation(
      senderName: "Alice",
      conversationTitle: "Alice",
      network: .instagram,
      text: "  "
    )
    XCTAssertEqual(shown.title, "Alice · Instagram")
    XCTAssertEqual(shown.body, "Nouveau message")
  }

  // MARK: - Le muet, seconde garde

  func testAMutedRoomIsNeverPresented() {
    let muted: Set<String> = ["!groupe:correspondance.local"]
    XCTAssertFalse(
      PushNotification.shouldPresent(roomID: "!groupe:correspondance.local", mutedRoomIDs: muted)
    )
    XCTAssertTrue(
      PushNotification.shouldPresent(roomID: "!dm-alice:correspondance.local", mutedRoomIDs: muted)
    )
  }

  func testMutedRoomsComeFromTheConversationStateSnapshot() {
    var snapshot = ConversationStateSnapshot()
    snapshot.muted = ["!groupe:correspondance.local"]
    snapshot.pinned = ["!dm-alice:correspondance.local"]
    XCTAssertEqual(SharedRelayState.mutedRoomIDs(in: snapshot), ["!groupe:correspondance.local"])
  }

  /// L'aller-retour par le conteneur du groupe d'app : c'est le seul chemin par
  /// lequel l'extension apprend qu'un salon est muet.
  func testMutedRoomIDsSurviveTheAppGroupRoundTrip() throws {
    let suite = "test.correspondance.push.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    XCTAssertEqual(SharedRelayState.mutedRoomIDs(suiteName: suite), [])
    SharedRelayState.saveMutedRoomIDs(["!a:s", "!b:s"], suiteName: suite)
    XCTAssertEqual(SharedRelayState.mutedRoomIDs(suiteName: suite), ["!a:s", "!b:s"])
    SharedRelayState.saveMutedRoomIDs([], suiteName: suite)
    XCTAssertEqual(SharedRelayState.mutedRoomIDs(suiteName: suite), [])
  }
}
