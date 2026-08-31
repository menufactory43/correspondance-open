import XCTest
@testable import CorrespondanceCore

/// Une demande est une conversation d'inconnu tenue hors de la file. Elle se
/// déduit — aucun pont mautrix ne l'annonce — et la déduction se teste ici.
final class ConversationRequestTests: XCTestCase {
  private func conversation(
    id: String = "instagram:!a:relais",
    preview: String = "Salut !",
    isGroup: Bool = false
  ) -> Conversation {
    Conversation(
      id: id,
      network: .instagram,
      address: "!a:relais",
      title: "Inconnu",
      preview: preview,
      lastMessageAt: Date(timeIntervalSince1970: 1_800_000_000),
      unreadCount: 1,
      isArchived: false,
      transportKey: "!a:relais",
      isGroup: isGroup
    )
  }

  func testUnInconnuQuiEcritEnPremierEstUneDemande() {
    XCTAssertTrue(
      RequestPolicy.isRequest(
        conversation(),
        signals: RequestSignals(hasWrittenBack: false, isKnownCorrespondent: false),
        decision: nil
      )
    )
  }

  func testUnFilQuOnNaPasChargeNeRangePersonne() {
    XCTAssertFalse(
      RequestPolicy.isRequest(
        conversation(),
        signals: RequestSignals(hasWrittenBack: nil),
        decision: nil
      ),
      "Dans le doute, la conversation reste dans la file."
    )
  }

  func testLeReseauQuiAnnonceUneDemandeSuffit() {
    XCTAssertTrue(
      RequestPolicy.isRequest(
        conversation(),
        signals: RequestSignals(hasWrittenBack: nil, isFlaggedByNetwork: true),
        decision: nil
      )
    )
  }

  func testUnFilNatifNEstJamaisUneDemande() {
    var natif = conversation(id: "imessage:+33612345678")
    natif = Conversation(
      id: natif.id, network: .iMessage, address: "+33612345678", title: "Inconnu",
      preview: "Salut !", lastMessageAt: natif.lastMessageAt, unreadCount: 1,
      isArchived: false, transportKey: natif.transportKey, isGroup: false
    )
    XCTAssertFalse(
      RequestPolicy.isRequest(natif, signals: RequestSignals(hasWrittenBack: false), decision: nil)
    )
  }

  func testAvoirReponduVautAcceptation() {
    XCTAssertFalse(
      RequestPolicy.isRequest(
        conversation(),
        signals: RequestSignals(hasWrittenBack: true),
        decision: nil
      )
    )
  }

  func testUnContactConnuNeDemandeRien() {
    XCTAssertFalse(
      RequestPolicy.isRequest(
        conversation(),
        signals: RequestSignals(hasWrittenBack: false, isKnownCorrespondent: true),
        decision: nil
      )
    )
  }

  func testUnGroupeNEstJamaisUneDemande() {
    XCTAssertFalse(
      RequestPolicy.isRequest(
        conversation(isGroup: true),
        signals: RequestSignals(hasWrittenBack: false),
        decision: nil
      ),
      "On quitte un groupe, on ne l'accepte pas."
    )
  }

  func testUnFilDeCatalogueSansMessageNeDemandeRien() {
    XCTAssertFalse(
      RequestPolicy.isRequest(
        conversation(preview: "Écrire sur Instagram…"),
        signals: RequestSignals(hasWrittenBack: false),
        decision: nil
      )
    )
  }

  func testUneDecisionPriseSortDesDemandes() {
    for decision in [ConversationRequest.Decision.accepted, .declined] {
      XCTAssertFalse(
        RequestPolicy.isRequest(
          conversation(),
          signals: RequestSignals(hasWrittenBack: false),
          decision: decision
        )
      )
    }
  }

  // MARK: - Le Relais

  func testLaDecisionFaitLAllerRetourParLAccountData() throws {
    for decision in [ConversationRequest.Decision.accepted, .declined] {
      let contenu = ConversationStateCodec.requestContent(decision)
      XCTAssertEqual(ConversationStateCodec.requestDecision(in: contenu), decision)
    }
    XCTAssertNil(ConversationStateCodec.requestDecision(in: ConversationStateCodec.requestContent(nil)))
  }

  func testLeSyncRendLaDecision() throws {
    let salon = "!a:relais"
    let json = """
    {"next_batch":"s2","rooms":{"join":{"\(salon)":{"account_data":{"events":[
      {"type":"fr.correspondance.request","content":{"decision":"accepted"}}
    ]}}}}}
    """
    var instantane = ConversationStateSnapshot()
    instantane.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)))
    XCTAssertEqual(instantane.requests[salon], .accepted)
  }

  // MARK: - La file

  func testUneDemandeResteHorsDeLaFileEtDuFocus() {
    let fil = conversation()
    var etat = InboxState()
    etat.pendingRequests = [fil.id]

    XCTAssertTrue(InboxOrdering.list([fil], scope: .inbox, network: nil, filter: .all, state: etat).isEmpty)
    XCTAssertTrue(InboxOrdering.focusQueue([fil], state: etat).isEmpty)
    XCTAssertEqual(
      InboxOrdering.list([fil], scope: .requests, network: nil, filter: .all, state: etat).map(\.id),
      [fil.id]
    )
  }

  func testAccepterFaitEntrerLaConversationDansLaFile() {
    let fil = conversation()
    var etat = InboxState()
    etat.requestDecisions[fil.id] = .accepted
    // Le store recalcule : décidée, elle n'est plus en attente.
    etat.pendingRequests = []

    XCTAssertEqual(
      InboxOrdering.list([fil], scope: .inbox, network: nil, filter: .all, state: etat).map(\.id),
      [fil.id]
    )
  }

  func testUneEcritureNonPartiePrimeSurLeRelais() {
    var file = RelayWriteQueue()
    file.enqueue(.request(roomID: "!a:relais", value: .declined))
    XCTAssertEqual(file.applied(to: ConversationStateSnapshot()).requests["!a:relais"], .declined)
    file.enqueue(.request(roomID: "!a:relais", value: .accepted))
    XCTAssertEqual(file.count, 1)
    XCTAssertEqual(file.applied(to: ConversationStateSnapshot()).requests["!a:relais"], .accepted)
  }
}
