import CorrespondanceCore
import Foundation
import OSLog

/// Ce que l'app Mac fait pour son extension de partage. Cf. `Partage` dans Core.
///
/// Sur Mac l'extension ne fait que **déposer** — sandboxée, elle ne sait ni
/// piloter Messages ni lire le Trousseau — puis elle ouvre
/// `correspondance://partage`. L'app vide alors la boîte : chaque dépôt part
/// par `send(session:)`, le chemin de tous les envois, iMessage compris.
extension InboxStore {
  private nonisolated static let journal = Logger(subsystem: "app.correspondance", category: "partage")

  /// L'index que la feuille de partage lit. Appelé à chaque changement de la
  /// liste ; on attend une seconde que la rafale passe, et on écrit une fois.
  func planifierIndexDuPartage() {
    partageIndexTask?.cancel()
    partageIndexTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self else { return }
      await self.ecrireIndexDuPartage()
    }
  }

  private func ecrireIndexDuPartage() async {
    guard !usingDemoData, let boite = PartageBoite.partagee() else { return }
    // Les photos : celles que le store a déjà, pour les cinquante fils les plus
    // récents. Au-delà, les initiales suffisent, et on ne télécharge rien ici.
    let recents = conversations.filter { !$0.isArchived }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }.prefix(50)
    var avatars: [String: String] = [:]
    for conversation in recents {
      guard let data = await ConversationAvatarStore.shared.imageData(for: conversation),
            let nom = boite.poserAvatar(data, cle: conversation.remoteAvatarID ?? conversation.id)
      else { continue }
      avatars[conversation.id] = nom
    }
    let index = Partage.index(conversations: conversations) { avatars[$0.id] }
    do {
      try boite.ecrire(index)
      boite.balayerAvatars(gardant: index)
    } catch {
      Self.journal.error("index du partage non écrit : \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Ce que l'extension a déposé part maintenant. Le fil s'ouvre d'abord, pour
  /// que la bulle se pose sous les yeux.
  func viderLaBoiteDuPartage() async {
    guard !usingDemoData, !partageVidageEnCours, let boite = PartageBoite.partagee() else { return }
    partageVidageEnCours = true
    defer { partageVidageEnCours = false }
    let depots = boite.enAttente()
    guard !depots.isEmpty else { return }
    WindowOpener.shared.openInbox()
    for depot in depots {
      let rowID = displayRowID(for: depot.conversationID)
      guard conversations.contains(where: { $0.id == rowID }) else {
        if depot.createdAt < Date().addingTimeInterval(-7 * 86_400) { boite.retirer(depot) }
        continue
      }
      let dossier = FileManager.default.temporaryDirectory
        .appendingPathComponent("partage-\(depot.id)", isDirectory: true)
      let fichiers: [URL]
      do {
        fichiers = try boite.retirer(depot, vers: dossier)
      } catch {
        Self.journal.error("dépôt illisible : \(error.localizedDescription, privacy: .public)")
        boite.retirer(depot)
        continue
      }
      mode = .inbox
      await select(rowID)
      let session = session(for: rowID)
      session.draftText = depot.text
      session.pendingAttachmentPaths = fichiers.map(\.path)
      await send(session: session)
    }
  }
}
