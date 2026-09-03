import Foundation
import CorrespondanceCore

/// Les gens du fil ouvert, pour le menu « @ » du composer.
///
/// Chaque réseau expose ses membres à sa façon : `chat_handle_join` pour
/// iMessage, `listGroups` pour Signal, les `m.room.member` pour un salon
/// bridgé. Quand il ne les expose pas (cache froid, historique partiel), ceux
/// qui ont déjà parlé dans le fil complètent la liste. Un fil fusionné réunit
/// les membres de tous ses réseaux, sans jamais montrer deux fois la même personne.
extension InboxStore {
  /// Les gens du fil de CETTE session, posés dans CETTE session. Rien ici ne
  /// regarde la sélection de l'inbox : une fenêtre détachée a ses mentions.
  func refreshMentionCandidates(for session: ConversationSession) async {
    let id = session.conversationID
    let thread = session.messages
    let members = isMerged(id)
      ? memberConversations(of: id)
      : (conversations.first { $0.id == id }).map { [$0] } ?? []

    var seen: Set<String> = []
    var result: [MentionCandidate] = []
    for conversation in members {
      for candidate in await mentionCandidates(in: conversation, thread: thread) {
        let key = MentionParser.fold(candidate.name)
        guard !key.isEmpty, seen.insert(key).inserted else { continue }
        result.append(candidate)
      }
    }
    // Le fil a pu se recharger pendant qu'on résolvait les noms — la session,
    // elle, ne change jamais de fil : ce qu'on a calculé lui appartient.
    session.mentionCandidates = result

    // Les agents présents : le composer le dit, sinon on ne sait qu'après le
    // premier message qu'un agent est là et qu'on peut le nommer.
    var agents: [String] = []
    for conversation in members where conversation.network.isMatrixBridged {
      for agent in await matrix.asideAgents(conversationID: conversation.id) where !agents.contains(agent) {
        agents.append(agent)
      }
    }
    session.asideAgents = agents
    // Les agents présents, aparté ou non : la note à soi et le fil d'un agent
    // n'ont pas d'aparté (cc y répond à tout), mais cc y est bien.
    var presents: [String] = []
    for conversation in members where conversation.network.livesOnRelay {
      for agent in await matrix.agentsPresent(conversationID: conversation.id) where !presents.contains(agent) {
        presents.append(agent)
      }
    }
    session.presentAgents = presents
    // Le sélecteur de réactions lit une liste statique : on lui dit ici si
    // les trois réservées à cc y ont leur place.
    if session === primarySession { Self.agentPresentInSelection = !presents.isEmpty }
  }

  private func mentionCandidates(
    in conversation: Conversation, thread: [ChatMessage]
  ) async -> [MentionCandidate] {
    guard conversation.isGroup else {
      // Tête-à-tête : une seule personne, celle du fil — et sa vraie photo.
      return [MentionCandidate(id: conversation.id, name: conversation.title, avatar: conversation)]
    }

    var out: [MentionCandidate] = []
    var known: Set<String> = []

    switch conversation.network {
    // Personne à mentionner dans une note à soi, ni dans un tête-à-tête avec
    // un agent : il répond sans qu'on le nomme.
    case .selfNote, .agent:
      break
    case .iMessage:
      for handle in conversation.participantHandles {
        let name = await ContactDirectory.shared.displayName(forHandle: handle)
          ?? spokenName(of: handle, in: conversation, thread: thread)
          ?? handle
        known.insert(handle)
        out.append(MentionCandidate(
          id: "\(conversation.network.rawValue):\(handle)",
          name: name,
          avatar: .avatarStub(network: conversation.network, address: handle, title: name)
        ))
      }
    case .signal, .whatsapp, .instagram, .messenger, .twitter, .slack:
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
    for message in thread where !message.isFromMe && message.conversationID == conversation.id {
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
  private func spokenName(
    of handle: String, in conversation: Conversation, thread: [ChatMessage]
  ) -> String? {
    thread.first {
      $0.conversationID == conversation.id && $0.senderID == handle
        && ($0.senderName?.isEmpty == false) && $0.senderName != handle
    }?.senderName
  }
}
