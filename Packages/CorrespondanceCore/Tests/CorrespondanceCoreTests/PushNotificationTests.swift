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

  /// Ce que la notification de conversation lit : la personne sans le réseau,
  /// le fil, le réseau à part. Le titre classique, lui, garde les deux.
  func testPresentationKeepsWhoAndWhereApart() {
    let shown = PushNotification.presentation(
      senderName: " Alice Martin ",
      conversationTitle: "Alice",
      network: .signal,
      text: "Salut"
    )
    XCTAssertEqual(shown.senderName, "Alice Martin")
    XCTAssertEqual(shown.conversationTitle, "Alice")
    XCTAssertEqual(shown.network, .signal)
    XCTAssertFalse(shown.isGroup)
    XCTAssertNil(shown.avatarMXC)

    // Sans auteur — un DM bridgé n'en donne pas toujours — le fil tient lieu
    // de personne, et c'est lui que la notification montre.
    let anonymous = PushNotification.presentation(
      senderName: nil, conversationTitle: "Julie", network: .whatsapp, text: "Ok")
    XCTAssertEqual(anonymous.senderName, "Julie")
  }

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

  // MARK: - Un média se nomme

  private func media(_ msgtype: String, body: String, mime: String? = nil, filename: String? = nil,
                     extra: [String: MatrixJSON] = [:]) -> MatrixJSON {
    var content: [String: MatrixJSON] = [
      "msgtype": .string(msgtype), "body": .string(body), "url": .string("mxc://relais/abc"),
    ]
    if let mime { content["info"] = .object(["mimetype": .string(mime)]) }
    if let filename { content["filename"] = .string(filename) }
    for (key, value) in extra { content[key] = value }
    return .object(content)
  }

  /// Le corps d'un vocal est son nom de fichier ; l'écran verrouillé dit
  /// « Message vocal » et sa durée, comme l'inbox.
  func testAVoiceNoteIsNamedWithItsDuration() {
    let content = media("m.audio", body: "PTT-20260922-WA0003.opus", mime: "audio/ogg", extra: [
      "org.matrix.msc3245.voice": .object([:]),
      "org.matrix.msc1767.audio": .object(["duration": .number(12_400)]),
    ])
    XCTAssertEqual(PushNotification.mediaBody(in: content), "🎤 Message vocal · 0:12")
    // Sans durée connue, le libellé seul — jamais « 0:00 ».
    let mute = media("m.audio", body: "x.ogg", extra: ["org.matrix.msc3245.voice": .object([:])])
    XCTAssertEqual(PushNotification.mediaBody(in: mute), "🎤 Message vocal")
    // Un audio sans la marque MSC3245 est un fichier audio, pas un vocal.
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.audio", body: "chanson.mp3", mime: "audio/mpeg")), "🎤 Message audio")
  }

  func testVideoPhotoAndGIFAreNamedNotSpelled() {
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.video", body: "VID_1234.mp4", mime: "video/mp4")), "🎥 Vidéo")
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.image", body: "IMG_0001.jpg", mime: "image/jpeg")), "📷 Photo")
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.image", body: "rire.gif", mime: "image/gif")), "GIF")
  }

  /// MSC2530 : `filename` porte le nom, `body` devient la légende — elle suit.
  func testACaptionFollowsTheLabel() {
    let content = media("m.image", body: "regarde ça", mime: "image/jpeg", filename: "IMG_0001.jpg")
    XCTAssertEqual(PushNotification.mediaBody(in: content), "📷 Photo : regarde ça")
    // Un pont qui répète le nom du fichier dans `body` n'écrit pas de légende.
    let repeated = media("m.image", body: "IMG_0001.jpg", mime: "image/jpeg", filename: "IMG_0001.jpg")
    XCTAssertEqual(PushNotification.mediaBody(in: repeated), "📷 Photo")
  }

  /// Un fichier garde son nom : c'est à ça qu'on reconnaît le contrat.
  func testAFileKeepsItsName() {
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.file", body: "contrat.pdf", mime: "application/pdf")), "📎 contrat.pdf")
    XCTAssertEqual(PushNotification.mediaBody(in: media("m.file", body: "")), "📎 Pièce jointe")
  }

  func testTextIsNotAMedia() {
    XCTAssertNil(PushNotification.mediaBody(in: .object(["msgtype": .string("m.text"), "body": .string("Salut")])))
  }

  // MARK: - L'archive tait

  /// Archiver, c'est ne plus rien voir : même un message qui me nomme se tait.
  func testAnArchivedRoomIsNeverPresented() {
    let archived: Set<String> = ["!range:correspondance.local"]
    XCTAssertFalse(PushNotification.shouldPresent(
      roomID: "!range:correspondance.local", mutedRoomIDs: [], archivedRoomIDs: archived, isPersonal: true))
    XCTAssertTrue(PushNotification.shouldPresent(
      roomID: "!dm-alice:correspondance.local", mutedRoomIDs: [], archivedRoomIDs: archived))
  }

  func testArchivedRoomsComeFromTheSnapshotAndSurviveTheRoundTrip() {
    var snapshot = ConversationStateSnapshot()
    snapshot.archived = ["!range:correspondance.local"]
    XCTAssertEqual(SharedRelayState.archivedRoomIDs(in: snapshot), ["!range:correspondance.local"])
    let suite = "test.correspondance.push.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    XCTAssertEqual(SharedRelayState.archivedRoomIDs(suiteName: suite), [])
    SharedRelayState.saveArchivedRoomIDs(["!a:s"], suiteName: suite)
    XCTAssertEqual(SharedRelayState.archivedRoomIDs(suiteName: suite), ["!a:s"])
  }

  /// Une ligne fusionnée dont un seul salon reste dehors n'est pas rangée :
  /// aucun de ses salons ne se tait, même celui qui porte encore un tag
  /// d'archive. Rangée en entier, elle se tait en entier. Le membre iMessage,
  /// sans salon, ne compte pas.
  func testAMergedRowIsSilencedOnlyWhenAllItsRoomsAreArchived() {
    let patate = MergedContact(
      title: "Patate",
      memberIDs: [
        "imessage:any;-;+33600000000",
        "signal:!signal:correspondance.local",
        "messenger:!messenger:correspondance.local",
      ],
      defaultConversationID: "signal:!signal:correspondance.local"
    )
    var snapshot = ConversationStateSnapshot()
    snapshot.mergedContacts = MergedContactStore.Stored(merged: [patate])
    snapshot.archived = ["!signal:correspondance.local", "!range:correspondance.local"]
    XCTAssertEqual(SharedRelayState.archivedRoomIDs(in: snapshot), ["!range:correspondance.local"])

    snapshot.archived.insert("!messenger:correspondance.local")
    XCTAssertEqual(
      SharedRelayState.archivedRoomIDs(in: snapshot),
      ["!signal:correspondance.local", "!messenger:correspondance.local", "!range:correspondance.local"]
    )
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
