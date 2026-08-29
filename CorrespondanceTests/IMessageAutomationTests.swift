import SQLite3
import XCTest

@testable import Correspondance

/// Lot M2 — ce qui se teste sans Messages.app : la machine à états de santé,
/// la table des tapbacks, et la vérification chat.db sur une fixture SQLite.
final class IMessageAutomationHealthTests: XCTestCase {
  private func probe(
    trusted: Bool = true,
    running: Bool = true,
    window: Bool = true,
    sidebar: Bool = true,
    transcript: Bool = true,
    os: String = "26.6.2"
  ) -> IMessageAXProbe {
    IMessageAXProbe(
      trusted: trusted,
      messagesRunning: running,
      windowFound: window,
      sidebarFound: sidebar,
      transcriptFound: transcript,
      menuBarFound: true,
      osVersion: os
    )
  }

  func testLeReglageEteintPrimeSurToutLeReste() {
    XCTAssertEqual(IMessageAutomationHealth.evaluate(probe(), enabled: false), .disabled)
    XCTAssertFalse(IMessageAutomationHealth.disabled.allowsActions)
  }

  func testSansAccessibiliteRienNEstTente() {
    let health = IMessageAutomationHealth.evaluate(probe(trusted: false), enabled: true)
    XCTAssertEqual(health, .accessibilityDenied)
    XCTAssertFalse(health.allowsActions)
    XCTAssertTrue(health.suggestsAccessibilitySettings)
  }

  func testMessagesEteinteResteActionnableOnLaLanceraCachee() {
    let health = IMessageAutomationHealth.evaluate(probe(running: false), enabled: true)
    XCTAssertEqual(health, .messagesNotRunning)
    XCTAssertTrue(health.allowsActions)
  }

  /// Le cas réellement rencontré sur cette machine : `AXIsProcessTrusted()` dit
  /// oui, mais l'arbre de la fenêtre reste opaque (autorisation périmée).
  func testAutorisationPerimeeSeVoitCommeArbreIllisible() {
    let health = IMessageAutomationHealth.evaluate(probe(window: false, sidebar: false, transcript: false), enabled: true)
    XCTAssertEqual(health, .treeUnreadable)
    XCTAssertFalse(health.allowsActions)
    XCTAssertTrue(health.suggestsAccessibilitySettings)
    XCTAssertTrue(health.labelFR().contains("périmée"))
  }

  func testUneSidebarSansTranscriptNeSuffitPas() {
    XCTAssertEqual(IMessageAutomationHealth.evaluate(probe(transcript: false), enabled: true), .treeUnreadable)
    XCTAssertEqual(IMessageAutomationHealth.evaluate(probe(sidebar: false), enabled: true), .treeUnreadable)
  }

  func testUneVersionNonValideeResteExperimentale() {
    let health = IMessageAutomationHealth.evaluate(probe(os: "27.0.0"), enabled: true)
    XCTAssertEqual(health, .experimental)
    XCTAssertTrue(health.allowsActions)
    XCTAssertTrue(health.labelFR(osVersion: "27.0.0").contains("27.0.0"))
  }

  func testMacOS26EstValidee() {
    XCTAssertEqual(IMessageAutomationHealth.evaluate(probe(), enabled: true), .ok)
    XCTAssertEqual(IMessageAutomationHealth.majorVersion(of: "26.6.2"), 26)
    XCTAssertNil(IMessageAutomationHealth.majorVersion(of: ""))
  }

  func testChaqueEtatSeDitEnFrancais() {
    let states: [IMessageAutomationHealth] = [
      .unknown, .disabled, .accessibilityDenied, .messagesNotRunning,
      .treeUnreadable, .experimental, .ok,
    ]
    for state in states {
      XCTAssertFalse(state.labelFR().isEmpty, "\(state) doit avoir un libellé")
    }
  }
}

final class IMessageTapbackTests: XCTestCase {
  /// Les six tapbacks natifs, et rien d'autre : un emoji libre est refusé.
  func testLesSixTapbacksSeReconnaissentParLeurEmoji() {
    XCTAssertEqual(IMessageTapback.matching(emoji: "❤️"), .heart)
    XCTAssertEqual(IMessageTapback.matching(emoji: "👍"), .thumbsUp)
    XCTAssertEqual(IMessageTapback.matching(emoji: "👎"), .thumbsDown)
    XCTAssertEqual(IMessageTapback.matching(emoji: "😂"), .ha)
    XCTAssertEqual(IMessageTapback.matching(emoji: "‼️"), .exclamation)
    XCTAssertEqual(IMessageTapback.matching(emoji: "❓"), .question)
    XCTAssertNil(IMessageTapback.matching(emoji: "🐙"))
  }

  /// La table d'émojis d'envoi doit coller à celle de lecture (`chat.db`),
  /// sinon poser ❤️ afficherait autre chose dans le fil.
  func testLaTableDEnvoiColleACelleDeLecture() {
    for (offset, tapback) in [
      (0, IMessageTapback.heart), (1, .thumbsUp), (2, .thumbsDown),
      (3, .ha), (4, .exclamation), (5, .question),
    ] {
      XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2000 + offset), tapback.emoji)
    }
  }

  func testChaqueTapbackPorteUnIdentifiantAXEtDesLibellesFR() {
    for tapback in IMessageTapback.allCases {
      XCTAssertTrue(tapback.axIdentifier.hasPrefix("acknowledgment.type."))
      XCTAssertFalse(tapback.frenchLabels.isEmpty)
    }
  }
}

/// Vérification chat.db sur une base fabriquée : c'est le juge de paix de chaque
/// action AX, donc il doit se tromper le moins possible.
final class IMessageAutomationVerifierTests: XCTestCase {
  private var directory: URL!
  private var verifier: IMessageAutomationVerifier!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("verif-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("chat.db")
    try Self.buildFixture(at: path)
    verifier = IMessageAutomationVerifier(databaseURL: path)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testLeFilEtLeMessageDoiventExisterAvantToutGeste() throws {
    XCTAssertEqual(try verifier.chatIdentifier(forChatGUID: "CHAT-A"), "+33600000000")
    XCTAssertNil(try verifier.chatIdentifier(forChatGUID: "CHAT-INCONNU"))

    let found = try XCTUnwrap(verifier.message(guid: "MSG-RECU", inChatGUID: "CHAT-A"))
    XCTAssertEqual(found.text, "Coucou")
    XCTAssertFalse(found.isFromMe)
    // Bon message, mauvais fil : on n'agit pas.
    XCTAssertNil(try verifier.message(guid: "MSG-RECU", inChatGUID: "CHAT-B"))
  }

  func testUnTapbackNeCompteQueSiIlEstDeMoiEtPosteApresLeRepere() throws {
    // Repère pris avant l'action : la ligne 10 existe déjà, elle ne compte pas.
    XCTAssertFalse(try verifier.hasTapback(targetGUID: "MSG-RECU", sinceRowID: 10, removal: false))
    XCTAssertTrue(try verifier.hasTapback(targetGUID: "MSG-RECU", sinceRowID: 9, removal: false))
    // Un retrait (3000) n'est pas une pose.
    XCTAssertFalse(try verifier.hasTapback(targetGUID: "MSG-AUTRE", sinceRowID: 0, removal: false))
    XCTAssertTrue(try verifier.hasTapback(targetGUID: "MSG-AUTRE", sinceRowID: 0, removal: true))
    // Le tapback de quelqu'un d'autre ne confirme pas le mien.
    XCTAssertFalse(try verifier.hasTapback(targetGUID: "MSG-ENVOYE", sinceRowID: 0, removal: false))
  }

  func testUneReponseCiteeSeLitDansThreadOriginatorGuid() throws {
    XCTAssertTrue(try verifier.hasReply(toGUID: "MSG-RECU", sinceRowID: 0))
    XCTAssertFalse(try verifier.hasReply(toGUID: "MSG-RECU", sinceRowID: 40))
    XCTAssertFalse(try verifier.hasReply(toGUID: "MSG-ENVOYE", sinceRowID: 0))
  }

  func testLeNonLuNeCompteQueLesMessagesRecus() throws {
    // Un tapback reçu n'est pas un message non lu.
    XCTAssertEqual(try verifier.unreadCount(chatGUID: "CHAT-A"), 1)
    XCTAssertEqual(try verifier.unreadCount(chatGUID: "CHAT-B"), 0)
  }

  func testEditionEtRetraitSeLisentSurLeursDates() throws {
    XCTAssertTrue(try verifier.isEdited(messageGUID: "MSG-MODIFIE"))
    XCTAssertFalse(try verifier.isEdited(messageGUID: "MSG-ENVOYE"))
    XCTAssertTrue(try verifier.isRetracted(messageGUID: "MSG-ANNULE"))
    XCTAssertFalse(try verifier.isRetracted(messageGUID: "MSG-ENVOYE"))
  }

  func testLeRepereAvantActionEstLeDernierROWID() throws {
    XCTAssertEqual(try verifier.latestMessageRowID(), 50)
  }

  func testUneAttenteSurUneConditionFausseExpireSansSePlaindre() async throws {
    let ok = await verifier.waitUntil(timeout: .milliseconds(300), poll: .milliseconds(50)) { false }
    XCTAssertFalse(ok)
    let immediate = await verifier.waitUntil(timeout: .milliseconds(300), poll: .milliseconds(50)) { true }
    XCTAssertTrue(immediate)
  }

  // MARK: - Fixture

  /// Un `chat.db` minimal au schéma macOS 26 : juste les colonnes que la
  /// vérification interroge.
  private static func buildFixture(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
      throw NSError(domain: "fixture", code: 1)
    }
    defer { sqlite3_close(db) }

    let schema = """
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, style INTEGER);
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, is_from_me INTEGER DEFAULT 0,
      is_read INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
      associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
      thread_originator_guid TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0
    );
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);

    INSERT INTO chat VALUES (1, 'CHAT-A', '+33600000000', 45);
    INSERT INTO chat VALUES (2, 'CHAT-B', '+33611111111', 45);

    -- Un reçu non lu, un envoyé, une modification, une annulation.
    INSERT INTO message (ROWID, guid, text, is_from_me, is_read) VALUES (1, 'MSG-RECU', 'Coucou', 0, 0);
    INSERT INTO message (ROWID, guid, text, is_from_me, is_read) VALUES (2, 'MSG-ENVOYE', 'Salut', 1, 1);
    INSERT INTO message (ROWID, guid, text, is_from_me, date_edited) VALUES (3, 'MSG-MODIFIE', 'Corrigé', 1, 777);
    INSERT INTO message (ROWID, guid, text, is_from_me, date_retracted) VALUES (4, 'MSG-ANNULE', '', 1, 888);
    INSERT INTO message (ROWID, guid, text, is_from_me, is_read) VALUES (5, 'MSG-AUTRE', 'Autre', 0, 1);

    -- Mon tapback ❤️ sur MSG-RECU (ROWID 10).
    INSERT INTO message (ROWID, guid, is_from_me, associated_message_guid, associated_message_type)
      VALUES (10, 'TB-MOI', 1, 'p:0/MSG-RECU', 2000);
    -- Mon retrait de tapback sur MSG-AUTRE (ROWID 20).
    INSERT INTO message (ROWID, guid, is_from_me, associated_message_guid, associated_message_type)
      VALUES (20, 'TB-RETRAIT', 1, 'p:0/MSG-AUTRE', 3000);
    -- Le tapback de quelqu'un d'autre sur mon message (ROWID 30) : ne confirme rien.
    INSERT INTO message (ROWID, guid, is_from_me, associated_message_guid, associated_message_type)
      VALUES (30, 'TB-LUI', 0, 'p:0/MSG-ENVOYE', 2001);
    -- Ma réponse citée à MSG-RECU (ROWID 40).
    INSERT INTO message (ROWID, guid, text, is_from_me, thread_originator_guid)
      VALUES (40, 'MSG-REPONSE', 'Oui !', 1, 'p:0/MSG-RECU');
    -- Une réponse citée reçue : ce n'est pas la mienne.
    INSERT INTO message (ROWID, guid, text, is_from_me, is_read, thread_originator_guid)
      VALUES (50, 'MSG-REPONSE-LUI', 'Non', 0, 1, 'p:0/MSG-ENVOYE');

    INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (1, 3), (1, 4), (2, 5),
      (1, 10), (1, 20), (1, 30), (1, 40), (1, 50);
    """
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "?"
      sqlite3_free(error)
      throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}
