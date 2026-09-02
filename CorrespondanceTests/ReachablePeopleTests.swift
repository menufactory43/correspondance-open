import XCTest
import CorrespondanceCore
@testable import Correspondance

/// La feuille « Nouvelle conversation » liste des personnes, pas des réseaux :
/// une même personne sur deux réseaux ne fait qu'une ligne, et un contact ne
/// se propose que là où on peut vraiment le joindre.
final class ReachablePeopleTests: XCTestCase {
  private func dm(_ id: String, network: MessageNetwork, address: String, title: String, at: Date = .now) -> Conversation {
    Conversation(
      id: id, network: network, address: address, title: title, preview: "ok",
      lastMessageAt: at, unreadCount: 0, isArchived: false, transportKey: address, isGroup: false
    )
  }

  func testSamePhoneOnTwoNetworksIsOnePersonWithTwoReaches() {
    let older = Date(timeIntervalSinceNow: -3600)
    let people = ReachablePeople.build(
      conversations: [
        dm("im", network: .iMessage, address: "+33612345678", title: "Aria", at: older),
        dm("wa", network: .whatsapp, address: "@whatsapp_33612345678:relais", title: "Aria (WA)"),
      ],
      members: { _ in [] },
      book: [],
      freshNetworks: [.iMessage, .whatsapp]
    )

    XCTAssertEqual(people.count, 1)
    let aria = people[0]
    XCTAssertEqual(aria.reaches.map(\.network), [.whatsapp, .iMessage], "le plus récent d'abord")
    XCTAssertTrue(aria.reaches.allSatisfy(\.isExisting))
    XCTAssertEqual(aria.avatar.id, "wa", "le portrait vient du fil qui a parlé en dernier")
    XCTAssertEqual(aria.reach(on: .whatsapp)?.conversationID, "wa")
    XCTAssertEqual(aria.reach(on: .iMessage)?.conversationID, "im")
  }

  func testWhatsAppOnlyContactNeverShowsUnderIMessage() {
    // Un fil WhatsApp dont l'adresse est un ghost sans numéro dans le carnet :
    // on ne sait pas le joindre ailleurs, il ne doit pas apparaître sous iMessage.
    let people = ReachablePeople.build(
      conversations: [dm("wa", network: .whatsapp, address: "@whatsapp_33699999999:relais", title: "Actal")],
      members: { _ in [] },
      book: [],
      freshNetworks: [.iMessage, .whatsapp]
    )

    XCTAssertEqual(ReachablePeople.filter(people, network: .whatsapp).count, 1)
    XCTAssertTrue(ReachablePeople.filter(people, network: .iMessage).isEmpty)
  }

  func testBookContactOffersFreshThreadsOnlyWhereItsHandleComposes() {
    let people = ReachablePeople.build(
      conversations: [],
      members: { _ in [] },
      book: [
        ContactDirectory.DirectoryHit(name: "Agence du Port", handle: "06 99 00 00 03"),
        ContactDirectory.DirectoryHit(name: "Agence du Port", handle: "agence@example.com"),
      ],
      freshNetworks: [.iMessage, .whatsapp]
    )

    XCTAssertEqual(people.count, 1, "deux identifiants du carnet, une seule personne")
    let agence = people[0]
    XCTAssertFalse(agence.isKnownOnRelay)
    XCTAssertEqual(agence.reaches.map(\.network), [.iMessage, .whatsapp])
    XCTAssertTrue(agence.reaches.allSatisfy { !$0.isExisting })
    XCTAssertEqual(agence.reach(on: .whatsapp)?.handle, "06 99 00 00 03", "l'e-mail n'ouvre pas WhatsApp")
  }

  func testBookNameWinsAndFreshNetworksCompleteAnExistingThread() {
    let people = ReachablePeople.build(
      conversations: [dm("im", network: .iMessage, address: "+33612345678", title: "+33612345678")],
      members: { _ in [] },
      book: [ContactDirectory.DirectoryHit(name: "Aria", handle: "06 12 34 56 78")],
      freshNetworks: [.iMessage, .whatsapp]
    )

    XCTAssertEqual(people.count, 1)
    XCTAssertEqual(people[0].name, "Aria")
    XCTAssertEqual(people[0].reaches.map(\.network), [.iMessage, .whatsapp])
    XCTAssertTrue(people[0].reaches[0].isExisting)
    XCTAssertFalse(people[0].reaches[1].isExisting, "WhatsApp reste à ouvrir")
    XCTAssertTrue(people[0].isKnownOnRelay)
    // Sous le filtre WhatsApp, cette personne n'a qu'un fil à ouvrir : elle
    // passe dans « Dans vos contacts », pas dans « Déjà en conversation ».
    XCTAssertFalse(ReachablePeople.filter(people, network: .whatsapp)[0].isKnownOnRelay)
  }

  func testMergedRowOpensAsOneLine() {
    let im = dm("im", network: .iMessage, address: "+33612345678", title: "Aria")
    let wa = dm("wa", network: .whatsapp, address: "@whatsapp_33612345678:relais", title: "Aria")
    let contact = MergedContact(title: "Aria", memberIDs: ["im", "wa"], defaultConversationID: "im")
    let rows = MergedContact.apply(to: [im, wa], merged: [contact])
    XCTAssertEqual(rows.count, 1)

    let people = ReachablePeople.build(
      conversations: rows,
      members: { id in id == contact.id ? [wa, im] : [] },
      book: [],
      freshNetworks: [.iMessage]
    )

    XCTAssertEqual(people.count, 1)
    XCTAssertEqual(Set(people[0].reaches.map(\.network)), [.iMessage, .whatsapp])
    XCTAssertTrue(people[0].reaches.allSatisfy { $0.conversationID == contact.id }, "chaque pastille ouvre la ligne fusionnée")
  }

  func testOrderingAndSearch() {
    let people = ReachablePeople.build(
      conversations: [
        dm("old", network: .iMessage, address: "+33611111111", title: "Zoé", at: Date(timeIntervalSinceNow: -86400)),
        dm("new", network: .iMessage, address: "+33622222222", title: "Bob"),
      ],
      members: { _ in [] },
      book: [
        ContactDirectory.DirectoryHit(name: "Yann", handle: "06 33 33 33 33"),
        ContactDirectory.DirectoryHit(name: "Alice", handle: "06 44 44 44 44"),
      ],
      freshNetworks: [.iMessage]
    )

    XCTAssertEqual(people.map(\.name), ["Bob", "Zoé", "Alice", "Yann"], "fils par récence, puis carnet par nom")
    XCTAssertEqual(people.filter { ReachablePeople.matches($0, query: "zoe") }.map(\.name), ["Zoé"])
    XCTAssertEqual(people.filter { ReachablePeople.matches($0, query: "0644") }.map(\.name), ["Alice"])
  }
}
