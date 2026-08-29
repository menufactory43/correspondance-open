import XCTest
@testable import Correspondance

/// La fusion de contacts : ce qu'on rapproche, ce qu'on refuse de rapprocher,
/// et à quoi ressemble la ligne unique une fois les deux fils réunis.
final class MergedContactTests: XCTestCase {
  private let origin = Date(timeIntervalSince1970: 1_700_000_000)

  private func conversation(
    _ id: String,
    network: MessageNetwork,
    address: String,
    title: String = "Vince",
    minutes: Double = 0,
    unread: Int = 0,
    archived: Bool = false,
    isGroup: Bool = false
  ) -> Conversation {
    Conversation(
      id: id,
      network: network,
      address: address,
      title: title,
      preview: "Aperçu \(id)",
      lastMessageAt: origin.addingTimeInterval(minutes * 60),
      unreadCount: unread,
      isArchived: archived,
      transportKey: "transport-\(id)",
      isGroup: isGroup,
      lastDelivery: nil
    )
  }

  // MARK: - Normalisation

  func testNormalizeLeadsSameNumberToSameKey() {
    let key = PhoneNormalizer.identityKey(for: "+33612345678")
    XCTAssertNotNil(key)
    XCTAssertEqual(PhoneNormalizer.identityKey(for: "0612345678"), key)
    XCTAssertEqual(PhoneNormalizer.identityKey(for: "@whatsapp_33612345678:correspondance.local"), key)
    XCTAssertEqual(PhoneNormalizer.identityKey(for: "whatsapp:33612345678"), key)
    XCTAssertEqual(PhoneNormalizer.identityKey(for: "33 6 12 34 56 78"), key)
  }

  func testNormalizeRefusesUUIDAndRoomIDs() {
    XCTAssertNil(PhoneNormalizer.identityKey(for: "8f14e45f-ceea-467a-9a3b-1c2d3e4f5061"))
    XCTAssertNil(PhoneNormalizer.identityKey(for: "!abcdef:correspondance.local"))
    XCTAssertNil(PhoneNormalizer.identityKey(for: "Groupe Signal"))
  }

  func testNormalizeKeepsEmails() {
    XCTAssertEqual(
      PhoneNormalizer.identityKey(for: "Vince@Example.com"),
      PhoneNormalizer.identityKey(for: "vince@example.com")
    )
    // Un numéro et une adresse ne se croisent jamais.
    XCTAssertNotEqual(
      PhoneNormalizer.identityKey(for: "vince@example.com"),
      PhoneNormalizer.identityKey(for: "+33612345678")
    )
  }

  // MARK: - Détection

  func testDetectsSameNumberAcrossNetworksDespiteFormats() {
    let imessage = conversation("imessage:1", network: .iMessage, address: "+33612345678", minutes: 10)
    let whatsapp = conversation("matrix:1", network: .whatsapp, address: "@whatsapp_33612345678:home", minutes: 20)
    let other = conversation("signal:9", network: .signal, address: "+33699999999")

    let groups = MergeCandidates.detect(in: [imessage, whatsapp, other], dismissedPairs: [])

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(Set(groups[0].map(\.id)), ["imessage:1", "matrix:1"])
    // Le plus récent ouvre le groupe : c'est lui qui donne le réseau par défaut.
    XCTAssertEqual(groups[0].first?.id, "matrix:1")
  }

  func testDetectsSharedEmailAcrossNetworks() {
    let imessage = conversation("imessage:mail", network: .iMessage, address: "Vince@Example.com")
    let signal = conversation("signal:mail", network: .signal, address: "vince@example.com")

    let groups = MergeCandidates.detect(in: [imessage, signal], dismissedPairs: [])
    XCTAssertEqual(groups.count, 1)
  }

  func testDoesNotDetectGroups() {
    let a = conversation("imessage:g", network: .iMessage, address: "+33612345678", isGroup: true)
    let b = conversation("matrix:g", network: .whatsapp, address: "whatsapp:33612345678", isGroup: true)

    XCTAssertTrue(MergeCandidates.detect(in: [a, b], dismissedPairs: []).isEmpty)
  }

  func testDoesNotDetectTwoChatsOnTheSameNetwork() {
    let a = conversation("imessage:1", network: .iMessage, address: "+33612345678")
    let b = conversation("imessage:2", network: .iMessage, address: "0612345678")

    XCTAssertTrue(MergeCandidates.detect(in: [a, b], dismissedPairs: []).isEmpty)
  }

  func testDismissedPairNeverComesBack() {
    let imessage = conversation("imessage:1", network: .iMessage, address: "+33612345678")
    let whatsapp = conversation("matrix:1", network: .whatsapp, address: "whatsapp:33612345678")
    let dismissed: Set<String> = [MergeCandidates.pairKey(["imessage:1", "matrix:1"])]

    XCTAssertTrue(MergeCandidates.detect(in: [imessage, whatsapp], dismissedPairs: dismissed).isEmpty)
    // La clé ne dépend pas de l'ordre.
    XCTAssertEqual(
      MergeCandidates.pairKey(["matrix:1", "imessage:1"]),
      MergeCandidates.pairKey(["imessage:1", "matrix:1"])
    )
  }

  // MARK: - Application

  func testApplyReplacesMembersWithASingleRow() {
    let imessage = conversation("imessage:1", network: .iMessage, address: "+33612345678", minutes: 10, unread: 2)
    let whatsapp = conversation("matrix:1", network: .whatsapp, address: "whatsapp:33612345678", minutes: 30, unread: 3)
    let other = conversation("signal:9", network: .signal, address: "+33699999999")
    let merged = MergedContact(
      id: "merged:vince",
      title: "Vince",
      memberIDs: ["imessage:1", "matrix:1"],
      defaultConversationID: "imessage:1"
    )

    let list = MergedContact.apply(to: [imessage, whatsapp, other], merged: [merged])

    XCTAssertEqual(list.count, 2)
    XCTAssertFalse(list.contains { $0.id == "imessage:1" || $0.id == "matrix:1" })
    let row = try! XCTUnwrap(list.first { $0.id == "merged:vince" })
    XCTAssertEqual(row.title, "Vince")
    // Somme des non-lus, réseau et aperçu du membre le plus récent.
    XCTAssertEqual(row.unreadCount, 5)
    XCTAssertEqual(row.network, .whatsapp)
    XCTAssertEqual(row.preview, "Aperçu matrix:1")
    XCTAssertEqual(row.lastMessageAt, whatsapp.lastMessageAt)
    // Adresse et transport viennent du chat par défaut : c'est là qu'on écrit.
    XCTAssertEqual(row.address, imessage.address)
    XCTAssertEqual(row.transportKey, imessage.transportKey)
    XCTAssertFalse(row.isGroup)
  }

  func testApplyArchivesOnlyWhenEveryMemberIsArchived() {
    let a = conversation("imessage:1", network: .iMessage, address: "+33612345678", archived: true)
    let b = conversation("matrix:1", network: .whatsapp, address: "whatsapp:33612345678", archived: false)
    let merged = MergedContact(
      id: "merged:v", title: "Vince",
      memberIDs: ["imessage:1", "matrix:1"], defaultConversationID: "imessage:1"
    )

    XCTAssertEqual(MergedContact.apply(to: [a, b], merged: [merged]).first?.isArchived, false)

    var bothArchived = b
    bothArchived.isArchived = true
    XCTAssertEqual(MergedContact.apply(to: [a, bothArchived], merged: [merged]).first?.isArchived, true)
  }

  func testApplyFallsBackWhenTheDefaultMemberIsGone() {
    let whatsapp = conversation("matrix:1", network: .whatsapp, address: "whatsapp:33612345678", minutes: 30)
    let signal = conversation("signal:1", network: .signal, address: "+33612345678", minutes: 5)
    let merged = MergedContact(
      id: "merged:v", title: "Vince",
      memberIDs: ["imessage:1", "matrix:1", "signal:1"],
      // Le membre par défaut n'est plus dans le catalogue.
      defaultConversationID: "imessage:1"
    )

    let row = try! XCTUnwrap(MergedContact.apply(to: [whatsapp, signal], merged: [merged]).first)
    XCTAssertEqual(row.id, "merged:v")
    // À défaut, tout vient du plus récent.
    XCTAssertEqual(row.address, whatsapp.address)
    XCTAssertEqual(row.transportKey, whatsapp.transportKey)
  }

  func testApplyIgnoresAMergeWithLessThanTwoPresentMembers() {
    let only = conversation("imessage:1", network: .iMessage, address: "+33612345678")
    let merged = MergedContact(
      id: "merged:v", title: "Vince",
      memberIDs: ["imessage:1", "matrix:1"], defaultConversationID: "imessage:1"
    )

    XCTAssertEqual(MergedContact.apply(to: [only], merged: [merged]).map(\.id), ["imessage:1"])
  }

  func testApplyIsIdempotent() {
    let a = conversation("imessage:1", network: .iMessage, address: "+33612345678")
    let b = conversation("matrix:1", network: .whatsapp, address: "whatsapp:33612345678")
    let merged = MergedContact(
      id: "merged:v", title: "Vince",
      memberIDs: ["imessage:1", "matrix:1"], defaultConversationID: "imessage:1"
    )

    let once = MergedContact.apply(to: [a, b], merged: [merged])
    XCTAssertEqual(MergedContact.apply(to: once, merged: [merged]), once)
  }

  func testLaRechercheRetrouveLaLigneParLAdresseDUnFilReplie() throws {
    let imessage = conversation("im", network: .iMessage, address: "+33612345678", minutes: 10)
    let whatsapp = conversation("wa", network: .whatsapp, address: "@whatsapp_33799887766:serveur")
    let contact = MergedContact(
      id: "merged:vince",
      title: "Vince",
      memberIDs: ["im", "wa"],
      defaultConversationID: "im"
    )
    let row = try XCTUnwrap(contact.row(from: [imessage, whatsapp]))
    // L'adresse portée par la ligne est celle du chat par défaut…
    XCTAssertEqual(row.address, "+33612345678")
    // …mais taper le numéro de l'autre chat la trouve quand même.
    XCTAssertEqual(
      ConversationSearch.filter([row], query: "33799887766", index: [:]).map(\.id),
      ["merged:vince"]
    )
    // Et une adresse qu'aucun des deux fils ne porte ne la trouve pas.
    XCTAssertTrue(ConversationSearch.filter([row], query: "33111111111", index: [:]).isEmpty)
  }

  func testActiveMemberPrefersTheLastUsedChat() {
    var merged = MergedContact(
      title: "Vince", memberIDs: ["imessage:1", "matrix:1"], defaultConversationID: "imessage:1"
    )
    XCTAssertEqual(merged.activeMemberID(among: ["imessage:1", "matrix:1"]), "imessage:1")

    merged.lastUsedConversationID = "matrix:1"
    XCTAssertEqual(merged.activeMemberID(among: ["imessage:1", "matrix:1"]), "matrix:1")
    // Le dernier utilisé a disparu : on retombe sur le défaut.
    XCTAssertEqual(merged.activeMemberID(among: ["imessage:1"]), "imessage:1")
  }
}
