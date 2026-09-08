import CorrespondanceCore
import Foundation
import OSLog

/// Ce que l'app fait pour l'extension de partage, et ce qu'elle fait de ce que
/// l'extension a laissé. Cf. `Partage` dans Core.
///
/// Deux gestes. **Écrire l'index** après chaque `/sync` : la liste des fils,
/// avec les photos déjà en cache, pour que la feuille de partage s'affiche
/// sans réseau. **Vider la boîte** au lancement et à chaque retour au premier
/// plan : ce que l'extension n'a pas pu envoyer elle-même (Relais muet, salon
/// chiffré) part par le chemin ordinaire — bulle optimiste comprise.
extension RelayStore {
  private nonisolated static let journal = Logger(subsystem: "app.correspondance", category: "partage")

  /// L'index que la feuille de partage lit. En arrière-plan : c'est un fichier
  /// JSON et quelques copies de photos, rien que l'écran attende.
  func ecrireIndexDuPartage() {
    guard !isDemo, let boite = PartageBoite.partagee() else { return }
    let rows = conversations
    // Un `/sync` qui n'a rien changé à la liste — un accusé, une frappe — ne
    // réécrit pas l'index : c'était une passe complète, mosaïques comprises,
    // toutes les quelques secondes.
    let empreinte = Self.empreinte(index(rows))
    guard empreinte != empreinteDuPartage else { return }
    empreinteDuPartage = empreinte
    // Les dix fils les plus récents deviennent des suggestions de partage :
    // la rangée des visages en haut de la feuille, avant tout message.
    for row in index(rows).prefix(10) {
      donnerSuggestionDePartage(row)
    }
    Task.detached(priority: .utility) {
      let index = Partage.index(conversations: rows) { conversation in
        guard let cle = Self.cleDuVisage(de: conversation) else { return nil }
        // Déjà dans la boîte : rien à composer ni à écrire.
        if let nom = boite.avatarPose(cle: cle) { return nom }
        guard let data = Self.visage(de: conversation, cle: cle) else { return nil }
        return boite.poserAvatar(data, cle: cle)
      }
      do {
        try boite.ecrire(index)
        boite.balayerAvatars(gardant: index)
      } catch {
        Self.journal.error("index du partage non écrit : \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func index(_ rows: [Conversation]) -> [Conversation] {
    rows.filter { !$0.isArchived && !$0.hasPlaceholderTitle }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  /// Le don sortant pour un fil — au rafraîchissement, et à chaque envoi.
  func donnerSuggestionDePartage(_ conversation: Conversation) {
    guard !isDemo, conversation.network != .agent else { return }
    let avatar = Self.cleDuVisage(de: conversation).flatMap { Self.visage(de: conversation, cle: $0) }
    CommunicationNotification.donnerEnvoi(
      conversationID: conversation.id, title: conversation.title, network: conversation.network,
      isGroup: conversation.isGroup, avatar: avatar
    )
  }

  /// Ce que l'extension a déposé part maintenant, un dépôt après l'autre, et
  /// le premier fil s'ouvre pour qu'on voie la bulle partir.
  func viderLaBoiteDuPartage() async {
    guard !isDemo, session == .connected, !partageVidageEnCours,
          let boite = PartageBoite.partagee()
    else { return }
    partageVidageEnCours = true
    defer { partageVidageEnCours = false }
    let depots = boite.enAttente()
    guard !depots.isEmpty else { return }
    var premier = true
    for depot in depots {
      guard conversations.contains(where: { $0.id == depot.conversationID }) else {
        // Un fil qu'on ne connaît plus : on le laisse une semaine, le temps
        // qu'un `/sync` le ramène, puis on jette plutôt que d'attendre sans fin.
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
      if premier {
        openConversationFromNotification(depot.conversationID)
        premier = false
      }
      setDraft(depot.text, conversationID: depot.conversationID)
      for fichier in fichiers { addAttachment(fichier.path, conversationID: depot.conversationID) }
      await send(conversationID: depot.conversationID)
    }
  }

  /// Ce qui distingue une liste de la précédente aux yeux de la feuille de
  /// partage : les fils, leur titre, leur photo, leur ordre.
  private static func empreinte(_ rows: [Conversation]) -> Int {
    var hasher = Hasher()
    for row in rows {
      hasher.combine(row.id); hasher.combine(row.title); hasher.combine(row.network)
      hasher.combine(row.remoteAvatarID); hasher.combine(row.memberAvatarIDs)
    }
    return hasher.finalize()
  }

  /// La clé de la photo du fil telle que l'inbox la montre : celle du portail,
  /// ou, pour un groupe qui n'en a pas — Instagram n'en donne jamais —, la
  /// liste des visages de sa mosaïque. `nil` quand il n'y a rien à montrer.
  nonisolated static func cleDuVisage(de conversation: Conversation) -> String? {
    if let mxc = conversation.remoteAvatarID, MatrixAvatarStore.hasData(forMXC: mxc) {
      return mxc
    }
    let ids = Array(conversation.memberAvatarIDs.prefix(4))
    guard ids.count >= 2 else { return nil }
    return "mosaique:" + ids.joined(separator: "|")
  }

  /// Les octets de cette photo, depuis le cache seulement — composés pour une
  /// mosaïque, à partir de visages réduits (une tuile fait 70 points).
  nonisolated static func visage(de conversation: Conversation, cle: String) -> Data? {
    if let mxc = conversation.remoteAvatarID, cle == mxc {
      return MatrixAvatarStore.existingData(forMXC: mxc)
    }
    let ids = Array(conversation.memberAvatarIDs.prefix(4))
    let faces = ids.compactMap { MatrixAvatarStore.existingData(forMXC: $0) }
      .compactMap { AttachmentThumbnailStore.downsample(data: $0, maxPixel: 160) }
    guard faces.count >= 2 else { return nil }
    return AvatarMosaic.compose(faces, size: 138, separator: .platformWindowBackground)
  }
}
