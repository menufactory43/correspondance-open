import CorrespondanceCore
import Foundation

/// Les conversations de démonstration : les payloads `/sync` des fixtures,
/// passés au vrai analyseur — la même recette que `DemoRelay` sur l'iPhone.
struct DemoCatalogue {
  var conversations: [Conversation] = []
  var messages: [String: [ChatMessage]] = [:]
  var typingLabels: [String: String] = [:]
  var state = InboxState()
  var merged: [MergedContact] = []

  /// `directory` vide : on cherche `CorrespondanceiOS/Demo` en remontant depuis
  /// le dossier courant — c'est un outil de développement.
  static func load(directory: String) -> DemoCatalogue? {
    guard let folder = locate(directory) else { return nil }
    DemoFixtures.seedAttachments()
    let selfUserID = DemoFixtures.selfUserID
    var rooms: [String: MatrixRoomModel] = [:]
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    for name in DemoFixtures.syncNames {
      let url = folder.appendingPathComponent("\(name).json")
      guard let raw = try? String(contentsOf: url, encoding: .utf8),
            let data = DemoFixtures.shiftingTimestamps(in: raw).data(using: .utf8),
            let response = try? JSONDecoder().decode(MatrixSyncResponse.self, from: data)
      else { continue }
      parser.apply(response, to: &rooms)
    }
    guard !rooms.isEmpty else { return nil }

    var catalogue = DemoCatalogue()
    for model in rooms.values {
      guard let conversation = model.conversation(selfUserID: selfUserID) else { continue }
      catalogue.conversations.append(conversation)
      catalogue.messages[conversation.id] = model.sortedMessages
      if let typing = model.typingLabelFR(now: Date(), selfUserID: selfUserID) {
        catalogue.typingLabels[conversation.id] = typing
      }
    }
    let ordered = InboxOrdering.sorted(catalogue.conversations, pinned: [])
    if let first = ordered.first { catalogue.state.pinned.insert(first.id) }
    if let last = ordered.last, ordered.count > 2 { catalogue.state.archived.insert(last.id) }
    if ordered.count > 1 { catalogue.state.drafts[ordered[1].id] = "Je te réponds ce soir, promis —" }
    if let muted = ordered.first(where: \.isGroup) { catalogue.state.muted.insert(muted.id) }
    return catalogue
  }

  private static func locate(_ directory: String) -> URL? {
    let fileManager = FileManager.default
    if !directory.isEmpty {
      let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
      return fileManager.fileExists(atPath: url.appendingPathComponent("matrix-sync-whatsapp.json").path) ? url : nil
    }
    var current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    for _ in 0..<8 {
      for candidate in ["CorrespondanceiOS/Demo", "Tests/CorrespondanceCoreTests/Fixtures", "Packages/CorrespondanceCore/Tests/CorrespondanceCoreTests/Fixtures"] {
        let url = current.appendingPathComponent(candidate)
        if fileManager.fileExists(atPath: url.appendingPathComponent("matrix-sync-whatsapp.json").path) { return url }
      }
      current.deleteLastPathComponent()
    }
    return nil
  }
}
