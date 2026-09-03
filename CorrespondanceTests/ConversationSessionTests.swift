import XCTest
import CorrespondanceCore
@testable import Correspondance

/// Une conversation ouverte tient son propre fil et son propre brouillon —
/// c'est ce qui permet à une fenêtre détachée de vivre à côté de l'inbox.
@MainActor
final class ConversationSessionTests: XCTestCase {
  private func conversation(
    id: String,
    network: MessageNetwork,
    title: String
  ) -> Conversation {
    Conversation(
      id: id,
      network: network,
      address: "adresse-\(id)",
      title: title,
      preview: "…",
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000),
      unreadCount: 0,
      isArchived: false,
      transportKey: id,
      isGroup: false
    )
  }

  private func message(id: String, conversationID: String, text: String) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: conversationID,
      network: .signal,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_700_000_100),
      isFromMe: false
    )
  }

  /// Deux fils, deux brouillons : écrire dans l'un ne touche pas l'autre.
  func testDraftsAreIsolatedPerThread() {
    let une = ConversationSession(conversationID: "une")
    let autre = ConversationSession(conversationID: "autre")

    une.draftText = "Bonjour"
    autre.draftText = "Autre chose"
    autre.pendingAttachmentPaths = ["/tmp/photo.png"]

    XCTAssertEqual(une.draftText, "Bonjour")
    XCTAssertTrue(une.pendingAttachmentPaths.isEmpty)
    XCTAssertEqual(autre.draftText, "Autre chose")
    XCTAssertTrue(une.hasDraft)

    une.clearDraft()
    XCTAssertFalse(une.hasDraft)
    XCTAssertEqual(autre.draftText, "Autre chose")
  }

  /// L'inbox et la fenêtre détachée d'un même fil demandent la même session :
  /// un message entrant se pose une fois et les deux pages le lisent.
  func testIncomingMessagesMergeIntoEveryViewOfAThread() {
    let store = InboxStore()
    store.conversations = [conversation(id: "sig:1", network: .signal, title: "Élise")]

    let depuisInbox = store.session(for: "sig:1")
    let depuisFenetre = store.session(for: "sig:1")
    XCTAssertTrue(depuisInbox === depuisFenetre)

    depuisInbox.messages.append(message(id: "m1", conversationID: "sig:1", text: "Tu es là ?"))
    XCTAssertEqual(depuisFenetre.messages.map(\.id), ["m1"])

    // Une session d'un AUTRE fil ne reçoit rien.
    let ailleurs = store.session(for: "sig:2")
    XCTAssertTrue(ailleurs.messages.isEmpty)
  }

  /// Le menu « @ » d'une fenêtre détachée cite les gens de SON fil, pas ceux
  /// du fil que l'inbox a sous les yeux. Deux composers, deux listes.
  func testMentionCandidatesBelongToTheirOwnSession() async {
    let store = InboxStore()
    var groupe = conversation(id: "sig:groupe", network: .signal, title: "Le groupe")
    groupe.isGroup = true
    store.conversations = [
      groupe,
      conversation(id: "imessage:paul", network: .iMessage, title: "Paul"),
    ]
    // L'inbox lit le groupe ; la fenêtre détachée lit le tête-à-tête.
    store.selectedConversationID = "sig:groupe"

    let inbox = store.session(for: "sig:groupe")
    let detachee = store.session(for: "imessage:paul")

    await store.refreshMentionCandidates(for: detachee)
    // Un tête-à-tête ne cite qu'une personne : celle du fil.
    XCTAssertEqual(detachee.mentionCandidates.map(\.name), ["Paul"])
    // Et rien n'est allé se poser dans la session de l'inbox.
    XCTAssertTrue(inbox.mentionCandidates.isEmpty)

    await store.refreshMentionCandidates(for: inbox)
    XCTAssertEqual(detachee.mentionCandidates.map(\.name), ["Paul"])
    XCTAssertFalse(inbox.mentionCandidates.contains { $0.name == "Paul" })
  }

  /// La session de l'inbox suit la sélection ; celle d'une fenêtre détachée non.
  func testPrimarySessionFollowsSelectionOnly() {
    let store = InboxStore()
    store.conversations = [
      conversation(id: "sig:1", network: .signal, title: "Élise"),
      conversation(id: "imessage:2", network: .iMessage, title: "Paul"),
    ]
    store.selectedConversationID = "sig:1"

    let detachee = store.session(for: "imessage:2")
    detachee.draftText = "À tout à l’heure"
    defer { detachee.clearDraft() }

    XCTAssertEqual(store.primarySession?.conversationID, "sig:1")
    // Le raccourci de l'inbox ne voit que SON brouillon.
    XCTAssertEqual(store.draftText, "")
    XCTAssertEqual(detachee.draftText, "À tout à l’heure")
  }

  /// Envoyer depuis une session qui n'est PAS sélectionnée part bien sur le fil
  /// de cette session : c'est son réseau qui répond, pas celui de l'inbox.
  func testSendFromAnUnselectedSessionRoutesToItsOwnThread() async {
    let store = InboxStore()
    store.conversations = [
      conversation(id: "sig:1", network: .signal, title: "Élise"),
      conversation(id: "imessage:2", network: .iMessage, title: "Paul"),
    ]
    // L'inbox lit le fil Signal ; Matrix est éteint, donc un envoi *là* dirait
    // « Matrix n'est pas connecté ».
    store.selectedConversationID = "sig:1"
    store.isMatrixConnected = false
    // Les données démo interdisent l'envoi iMessage, avec un message à elles.
    store.usingDemoData = true

    let detachee = store.session(for: "imessage:2")
    detachee.draftText = "Je descends."
    defer { detachee.clearDraft() }

    await store.send(session: detachee)

    XCTAssertEqual(
      store.lastErrorMessage,
      "Données de démonstration. Autorise l’accès au disque pour envoyer par Messages."
    )
    // Le brouillon refusé reste dans SA session, et l'inbox n'a rien vu passer.
    XCTAssertEqual(detachee.draftText, "Je descends.")
    XCTAssertEqual(store.primarySession?.draftText, "")
    XCTAssertTrue(store.primarySession?.messages.isEmpty ?? false)
  }
}
