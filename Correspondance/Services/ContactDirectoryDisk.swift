import Foundation

/// Lecture sync du cache Contacts sur disque — pour hydrater l’inbox au lancement (0 latence).
enum ContactDirectoryDisk {
  private static var indexURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("Correspondance", isDirectory: true)
      .appendingPathComponent("contacts-index.json")
  }

  private struct DiskIndex: Codable {
    var names: [String: String]
    var imageFiles: [String: String]
    var savedAt: Date
  }

  static func enrichIMessageTitles(_ conversations: inout [Conversation]) {
    guard let data = try? Data(contentsOf: indexURL),
          let disk = try? JSONDecoder().decode(DiskIndex.self, from: data),
          !disk.names.isEmpty
    else { return }

    for index in conversations.indices {
      guard conversations[index].network == .iMessage else { continue }
      var conversation = conversations[index]
      let peerHandles = handles(for: conversation)

      if conversation.isGroup {
        if !conversation.hasPlaceholderTitle { continue }
        let resolved = peerHandles.prefix(4).compactMap { name(in: disk.names, for: $0) }
        if !resolved.isEmpty {
          let label = resolved.joined(separator: ", ")
            + (peerHandles.count > resolved.count ? "…" : "")
          conversation.preferTitle(label)
        }
      } else if conversation.hasPlaceholderTitle {
        let peer = peerHandles.first ?? conversation.address
        if let resolved = name(in: disk.names, for: peer) {
          conversation.preferTitle(resolved)
        }
      }
      conversations[index] = conversation
    }
  }

  private static func name(in names: [String: String], for handle: String) -> String? {
    for key in lookupKeys(for: handle) {
      if let value = names[key] { return value }
    }
    return nil
  }

  private static func handles(for conversation: Conversation) -> [String] {
    let parts = conversation.transportKey
      .split(separator: "|", omittingEmptySubsequences: false)
      .map(String.init)
    if parts.count >= 4 {
      let listed = parts[3]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !listed.isEmpty { return listed }
    }
    let address = conversation.address.trimmingCharacters(in: .whitespacesAndNewlines)
    if address.hasPrefix("chat") { return [] }
    return address.isEmpty ? [] : [address]
  }

  private static func lookupKeys(for handle: String) -> [String] {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if trimmed.contains("@") { return [trimmed.lowercased()] }
    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return [trimmed.lowercased()] }
    var keys: Set<String> = [digits]
    for n in [8, 9, 10] where digits.count >= n {
      keys.insert(String(digits.suffix(n)))
    }
    if digits.hasPrefix("33"), digits.count >= 11 {
      let national = String(digits.dropFirst(2))
      keys.insert("0" + national)
      keys.insert(national)
    }
    if digits.hasPrefix("0"), digits.count >= 10 {
      let national = String(digits.dropFirst())
      keys.insert("33" + national)
      keys.insert(national)
    }
    return Array(keys)
  }
}
