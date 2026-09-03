import CorrespondanceCore
import Foundation

extension InboxStore {
  /// Le lancement en démonstration : rien n'est lu chez l'utilisateur, rien
  /// n'est demandé (Contacts, Automatisation, notifications), rien ne part.
  func startDemo() async {
    DemoFixtures.seedAttachments()
    for name in DemoFixtures.syncNames {
      guard let response = DemoFixtures.response(named: name) else { continue }
      await matrix.ingestDemo(response, selfUserID: DemoMode.selfUserID)
    }
    let bridged = await matrix.conversations()
    let local = DemoMode.iMessageConversations()
    demoMessagesByID = DemoMode.iMessageMessages()

    iMessageStatusFR = "Démonstration : \(local.count) conversations inventées."
    matrixStatusFR = "Démonstration : \(MatrixBridgeService.bridgedCountFR(bridged))."
    contactsStatusFR = "Démonstration."
    notificationStatusFR = "Démonstration."
    chiffrementFR = "Démonstration."
    isMatrixConnected = true
    didSettleInitialMatrixSync = true
    isInitialSync = false

    // Un peu d'état, pour que sections et filtres aient quelque chose à montrer :
    // le fil le plus récent épinglé, le plus ancien archivé, un groupe en muet.
    let all = (local + bridged).sorted { $0.lastMessageAt > $1.lastMessageAt }
    var pinned: Set<String> = [], archived: Set<String> = [], muted: Set<String> = []
    if let first = all.first { pinned.insert(first.id) }
    if let last = all.last, all.count > 3 { archived.insert(last.id) }
    if let group = bridged.first(where: \.isGroup) { muted.insert(group.id) }
    applyDemoState(conversations: all, pinned: pinned, archived: archived, muted: muted)

    let wanted = DemoMode.requestedSelection?.lowercased()
    let chosen = wanted.flatMap { title in all.first { $0.title.lowercased() == title } }
    await select(chosen?.id ?? inboxRecents.first?.id ?? activeQueue.first?.id)
  }
}
