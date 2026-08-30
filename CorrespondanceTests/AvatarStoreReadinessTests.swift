import AppKit
import XCTest
@testable import Correspondance

/// Au lancement, les lignes de l'inbox demandent leur photo avant que le chargeur
/// Matrix ne soit posé. Le store doit l'attendre, pas répondre « pas de photo ».
final class AvatarStoreReadinessTests: XCTestCase {
  private func group(_ id: String, members: [String]) -> Conversation {
    var c = Conversation(
      id: id, network: .instagram, address: "!salon:correspondance.local",
      title: "Agence Lyon", preview: "ok", lastMessageAt: .now, unreadCount: 0,
      isArchived: false, transportKey: "!salon:correspondance.local", isGroup: true
    )
    c.memberAvatarIDs = members
    return c
  }

  private func dm(_ id: String, avatar: String) -> Conversation {
    var c = Conversation(
      id: id, network: .instagram, address: "!dm:correspondance.local",
      title: "Camille", preview: "ok", lastMessageAt: .now, unreadCount: 0,
      isArchived: false, transportKey: "!dm:correspondance.local", isGroup: false
    )
    c.remoteAvatarID = avatar
    return c
  }

  /// Une pastille 2×2 en PNG : de quoi nourrir une mosaïque sans toucher au disque.
  private static let pixel: Data = {
    let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
      NSColor.systemPink.setFill(); rect.fill(); return true
    }
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
  }()

  func testPortalAvatarWaitsForTheLoader() async {
    let store = ConversationAvatarStore()
    let conversation = dm("instagram:!dm", avatar: "mxc://correspondance.local/photo")
    async let requested = store.imageData(for: conversation)
    try? await Task.sleep(for: .milliseconds(250))
    let payload = Data("photo".utf8)
    await store.setMatrixAvatarLoader { _ in payload }
    let data = await requested
    XCTAssertEqual(data, payload)
  }

  func testGroupMosaicWaitsForTheLoader() async {
    let store = ConversationAvatarStore()
    let conversation = group("instagram:!salon", members: ["mxc://c.l/a", "mxc://c.l/b", "mxc://c.l/c", "mxc://c.l/d"])
    async let requested = store.imageData(for: conversation)
    try? await Task.sleep(for: .milliseconds(250))
    let pixel = Self.pixel
    await store.setMatrixAvatarLoader { _ in pixel }
    let data = await requested
    XCTAssertNotNil(data.flatMap(NSImage.init(data:)), "la mosaïque doit se composer une fois le chargeur arrivé")
  }

  func testSenderFaceIsNotBurnedAsMissingBeforeTheLoader() async {
    let store = SenderAvatarStore()
    async let requested = store.imageData(
      conversationID: "instagram:!salon", senderID: "@instagram_42:correspondance.local", network: .instagram
    )
    try? await Task.sleep(for: .milliseconds(250))
    let payload = Data("visage".utf8)
    await store.setMatrixMemberAvatarLoader { _, _ in payload }
    let first = await requested
    XCTAssertEqual(first, payload)
    let again = await store.imageData(
      conversationID: "instagram:!salon", senderID: "@instagram_42:correspondance.local", network: .instagram
    )
    XCTAssertEqual(again, payload)
  }

  /// Sans pont du tout (tests, aperçus), le store finit par répondre — il ne pend pas.
  func testStoreWithoutBridgeStillAnswers() async {
    let store = ConversationAvatarStore()
    let started = Date()
    let data = await store.imageData(for: dm("instagram:!seul", avatar: "mxc://c.l/x"))
    XCTAssertNil(data)
    XCTAssertLessThan(Date().timeIntervalSince(started), 8)
  }
}
