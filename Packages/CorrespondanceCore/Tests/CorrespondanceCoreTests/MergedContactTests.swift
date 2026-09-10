import XCTest
@testable import CorrespondanceCore

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
    // Un autre nom : le même nom rapprocherait aussi, et c'est voulu.
    let other = conversation("signal:9", network: .signal, address: "+33699999999", title: "Autre")

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

  // MARK: - E.164

  /// Ce que la feuille « Nouvelle conversation » compose : le numéro que le
  /// bot du pont attend, ou rien.
  func testE164KeepsOnlyWhatCanBeDialled() {
    XCTAssertEqual(PhoneNormalizer.e164("+33 6 12 34 56 78"), "+33612345678")
    XCTAssertEqual(PhoneNormalizer.e164("06 12 34 56 78"), "+33612345678")
    XCTAssertEqual(PhoneNormalizer.e164("0033612345678"), "+33612345678")
    // Un pseudo n'est pas un numéro, un fil non plus, et sept chiffres non plus.
    XCTAssertNil(PhoneNormalizer.e164("alice.martin"))
    XCTAssertNil(PhoneNormalizer.e164("!salon:correspondance.local"))
    XCTAssertNil(PhoneNormalizer.e164("1234567"))
  }
}

// MARK: - Nom identique, et ligne qui accueille

extension MergedContactTests {
  func testDetectsIdenticalNameAcrossNetworksWithoutAnyNumber() {
    let signal = conversation("sig", network: .signal, address: "!room1:relais", title: "Marie-Françoise")
    let insta = conversation("ig", network: .instagram, address: "!room2:relais", title: "marie-francoise")
    let other = conversation("ig2", network: .instagram, address: "!room3:relais", title: "Marie")
    let groups = MergeCandidates.detect(in: [signal, insta, other], dismissedPairs: [])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(Set(groups[0].map(\.id)), ["sig", "ig"])
  }

  func testNameAndNumberKeysJoinIntoOneGroup() {
    let im = conversation("im", network: .iMessage, address: "+33612345678", title: "Vince")
    let wa = conversation("wa", network: .whatsapp, address: "@whatsapp_33612345678:relais", title: "Vince WA")
    let sig = conversation("sig", network: .signal, address: "!room:relais", title: "Vince")
    let groups = MergeCandidates.detect(in: [im, wa, sig], dismissedPairs: [])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(Set(groups[0].map(\.id)), ["im", "wa", "sig"])
  }

  func testPlaceholderOrNumericTitlesNeverMatchByName() {
    let a = conversation("a", network: .signal, address: "!r1:relais", title: "!r1:relais")
    let b = conversation("b", network: .instagram, address: "!r2:relais", title: "!r1:relais")
    let c = conversation("c", network: .signal, address: "!r3:relais", title: "+33612345678")
    let d = conversation("d", network: .instagram, address: "!r4:relais", title: "+33612345678")
    XCTAssertTrue(MergeCandidates.detect(in: [a, b, c, d], dismissedPairs: []).isEmpty)
  }

  func testAbsorbingAddsAThreadAndSwallowsAnotherMergedLine() {
    let prune = MergedContact(id: "merged:p", title: "Pastèque", memberIDs: ["im", "wa"], defaultConversationID: "im")
    let julie = MergedContact(id: "merged:j", title: "Julie", memberIDs: ["ms", "ig"], defaultConversationID: "ms")
    let result = prune.absorbing(["sig", "merged:j", "im"], contacts: [prune, julie])
    XCTAssertEqual(result.contact.memberIDs, ["im", "wa", "sig", "ms", "ig"])
    XCTAssertEqual(result.contact.title, "Pastèque")
    XCTAssertEqual(result.contact.defaultConversationID, "im")
    XCTAssertEqual(result.absorbed.map(\.id), ["merged:j"])
  }

  func testPhoneEmbeddedInTitleOrTopic() {
    XCTAssertEqual(MatrixIdentity.phoneNumber(embeddedIn: "Signal (+33699000001)"), "+33699000001")
    XCTAssertEqual(MatrixIdentity.phoneNumber(embeddedIn: "Signal private chat with +33 6 12 34 56 78"), "+33612345678")
    XCTAssertEqual(MatrixIdentity.phoneNumber(embeddedIn: "Agence 06 99 00 00 03"), "+33699000003")
    XCTAssertNil(MatrixIdentity.phoneNumber(embeddedIn: "Signal private chat"))
    XCTAssertNil(MatrixIdentity.phoneNumber(embeddedIn: "whatsapp_lid-1234567890"))
    XCTAssertNil(MatrixIdentity.phoneNumber(embeddedIn: "Julie Wsp 100091001567594"), "un identifiant Meta n'est pas un numéro")
    XCTAssertNil(MatrixIdentity.phoneNumber(embeddedIn: "Promo 2024"))
  }

  func testRowKeepsAPhotoFromItsMembers() {
    let signal = Conversation(
      id: "signal:!a:r", network: .signal, address: "uuid", title: "Julie", preview: "",
      lastMessageAt: Date(timeIntervalSince1970: 100), unreadCount: 0, isArchived: false,
      transportKey: "!a:r", isGroup: false, remoteAvatarID: nil)
    let whatsapp = Conversation(
      id: "whatsapp:!b:r", network: .whatsapp, address: "+33", title: "Julie", preview: "",
      lastMessageAt: Date(timeIntervalSince1970: 50), unreadCount: 0, isArchived: false,
      transportKey: "!b:r", isGroup: false, remoteAvatarID: "mxc://r/julie")
    let contact = MergedContact(
      id: "merged:1", title: "Julie", memberIDs: [signal.id, whatsapp.id], defaultConversationID: signal.id)
    XCTAssertEqual(contact.row(from: [signal, whatsapp])?.remoteAvatarID, "mxc://r/julie")
  }

  /// Le visage choisi à la fusion prime sur celui du chat par défaut : c'est
  /// la seule photo que l'iPhone connaît d'une ligne fusionnée.
  func testRowPrefersTheFaceChosenAtMergeTime() {
    let signal = Conversation(
      id: "signal:!a:r", network: .signal, address: "uuid", title: "Julie", preview: "",
      lastMessageAt: Date(timeIntervalSince1970: 100), unreadCount: 0, isArchived: false,
      transportKey: "!a:r", isGroup: false, remoteAvatarID: "mxc://r/julie-signal")
    let whatsapp = Conversation(
      id: "whatsapp:!b:r", network: .whatsapp, address: "+33", title: "Julie", preview: "",
      lastMessageAt: Date(timeIntervalSince1970: 50), unreadCount: 0, isArchived: false,
      transportKey: "!b:r", isGroup: false, remoteAvatarID: "mxc://r/julie-whatsapp")
    let contact = MergedContact(
      id: "merged:1", title: "Julie", memberIDs: [signal.id, whatsapp.id],
      avatarConversationID: whatsapp.id, defaultConversationID: signal.id)
    XCTAssertEqual(contact.row(from: [signal, whatsapp])?.remoteAvatarID, "mxc://r/julie-whatsapp")
    // Sans choix, le chat par défaut garde la main.
    let plain = MergedContact(
      id: "merged:2", title: "Julie", memberIDs: [signal.id, whatsapp.id], defaultConversationID: signal.id)
    XCTAssertEqual(plain.row(from: [signal, whatsapp])?.remoteAvatarID, "mxc://r/julie-signal")
  }

  func testReadableAddressHidesTechnicalIdentifiers() {
    XCTAssertEqual(
      conversation("w", network: .whatsapp, address: "@whatsapp_33612345678:correspondance.local").readableAddress,
      "+33612345678")
    XCTAssertNil(conversation("s", network: .signal, address: "3fa85f64-5717-4562-b3fc-2c963f66afa6").readableAddress)
    XCTAssertNil(conversation("m", network: .messenger, address: "17841400000000001").readableAddress)
    XCTAssertEqual(
      conversation("m", network: .messenger, address: "17841400000000001").networkAndReadableAddress,
      MessageNetwork.messenger.labelFR)
  }
}
