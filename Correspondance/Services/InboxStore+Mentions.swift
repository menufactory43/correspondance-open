import Foundation

/// Les gens du fil ouvert, pour le menu « @ » du composer.
///
/// Chaque réseau expose ses membres à sa façon : `chat_handle_join` pour
/// iMessage, `listGroups` pour Signal, les `m.room.member` pour un salon
/// bridgé. Quand il ne les expose pas (cache froid, historique partiel), ceux
/// qui ont déjà parlé dans le fil complètent la liste. Un fil fusionné réunit
/// les membres de tous ses réseaux, sans jamais montrer deux fois la même personne.
extension InboxStore {
  func refreshMentionCandidates() async {
    guard let id = selectedConversationID else {
      mentionCandidates = []
      return
    }
    let members = isMerged(id)
      ? memberConversations(of: id)
      : (conversations.first { $0.id == id }).map { [$0] } ?? []

    var seen: Set<String> = []
    var result: [MentionCandidate] = []
    for conversation in members {
      for candidate in await mentionCandidates(in: conversation) {
        let key = MentionParser.fold(candidate.name)
        guard !key.isEmpty, seen.insert(key).inserted else { continue }
        result.append(candidate)
      }
    }
    // Le fil a pu changer pendant qu'on résolvait les noms : ne pas poser la
    // liste d'un autre fil sur celui-ci.
    guard selectedConversationID == id else { return }
    mentionCandidates = result
  }

  private func mentionCandidates(in conversation: Conversation) async -> [MentionCandidate] {
    guard conversation.isGroup else {
      // Tête-à-tête : une seule personne, celle du fil — et sa vraie photo.
      return [MentionCandidate(id: conversation.id, name: conversation.title, avatar: conversation)]
    }

    var out: [MentionCandidate] = []
    var known: Set<String> = []

    switch conversation.network {
    case .iMessage, .signal:
      let me = conversation.network == .signal ? await signal.accountNumber() : nil
      for handle in conversation.participantHandles where handle != me {
        let name = await ContactDirectory.shared.displayName(forHandle: handle)
          ?? spokenName(of: handle, in: conversation)
          ?? handle
        known.insert(handle)
        out.append(MentionCandidate(
          id: "\(conversation.network.rawValue):\(handle)",
          name: name,
          avatar: .avatarStub(network: conversation.network, address: handle, title: name)
        ))
      }
    case .whatsapp, .instagram:
      for member in await matrix.members(conversationID: conversation.id) {
        let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (name?.isEmpty == false) ? name! : MatrixIdentity.localpart(member.userID)
        known.insert(member.userID)
        out.append(MentionCandidate(
          id: "\(conversation.network.rawValue):\(member.userID)",
          name: title,
          avatar: .avatarStub(
            network: conversation.network, address: member.userID, title: title,
            remoteAvatarID: member.avatarMXC
          )
        ))
      }
    }

    // Ceux qui ont parlé sans figurer dans la liste du réseau.
    for message in messages where !message.isFromMe && message.conversationID == conversation.id {
      guard let label = MessageGrouping.label(for: message) else { continue }
      let handle = message.senderID ?? label
      guard known.insert(handle).inserted else { continue }
      let name = label == handle
        ? (await ContactDirectory.shared.displayName(forHandle: handle) ?? label)
        : label
      out.append(MentionCandidate(
        id: "\(conversation.network.rawValue):\(handle)",
        name: name,
        avatar: .avatarStub(network: conversation.network, address: handle, title: name)
      ))
    }
    return out
  }

  /// Le nom sous lequel cette adresse a déjà parlé dans le fil, s'il y en a un.
  private func spokenName(of handle: String, in conversation: Conversation) -> String? {
    messages.first {
      $0.conversationID == conversation.id && $0.senderID == handle
        && ($0.senderName?.isEmpty == false) && $0.senderName != handle
    }?.senderName
  }
}
