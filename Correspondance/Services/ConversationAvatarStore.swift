import AppKit
import Foundation

/// Résout les photos de profil / groupes (Signal disque + Contacts iMessage).
actor ConversationAvatarStore {
  static let shared = ConversationAvatarStore()

  private var memory: [String: Data] = [:]

  private var signalAvatarsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/signal-cli/avatars", isDirectory: true)
  }

  func imageData(for conversation: Conversation) async -> Data? {
    if let cached = memory[conversation.id] { return cached }

    let resolved: Data?
    switch conversation.network {
    case .signal:
      resolved = loadSignalAvatarData(for: conversation)
    case .iMessage:
      resolved = await ContactDirectory.shared.imageData(for: conversation)
    }

    if let resolved {
      memory[conversation.id] = resolved
    }
    return resolved
  }

  func invalidate(conversationID: String) {
    memory.removeValue(forKey: conversationID)
  }

  // MARK: - Signal

  /// signal-cli remplace `/` par `_` dans les noms de fichiers avatar.
  private func signalAvatarFilenameStem(_ raw: String) -> String {
    raw.replacingOccurrences(of: "/", with: "_")
  }

  private func loadSignalAvatarData(for conversation: Conversation) -> Data? {
    let dir = signalAvatarsDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

    let candidates: [String]
    if conversation.isGroup || conversation.id.hasPrefix("signal-group:") {
      let stems = [
        signalAvatarFilenameStem(conversation.address),
        signalAvatarFilenameStem(conversation.transportKey),
      ]
      candidates = stems.flatMap { ["group-\($0)"] }
    } else {
      let address = conversation.address
      let bare = address.hasPrefix("+") ? String(address.dropFirst()) : address
      let stems = [address, bare].map(signalAvatarFilenameStem)
      candidates = stems.flatMap { ["profile-\($0)", "contact-\($0)"] }
    }

    for name in candidates {
      let url = dir.appendingPathComponent(name)
      if let data = try? Data(contentsOf: url), !data.isEmpty {
        return data
      }
    }

    // Fallback: préfixe (group ids / encodage).
    let needle = signalAvatarFilenameStem(conversation.address)
    let prefix = conversation.isGroup ? "group-" : "profile-"
    if needle.count >= 12,
       let match = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .first(where: {
          let name = $0.lastPathComponent
          return name.hasPrefix(prefix) && name.contains(String(needle.prefix(16)))
        }),
       let data = try? Data(contentsOf: match), !data.isEmpty
    {
      return data
    }
    return nil
  }
}
