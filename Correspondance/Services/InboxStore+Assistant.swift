import CorrespondanceCore
import Foundation

/// Les comportements de « cc » vus depuis le fil : la réponse proposée sans
/// qu'on demande, le résumé, l'aparté envoyé par un geste (une réaction
/// réservée, le bouton Résumer). Cf. `docs/PLAN-cc-comportements.md`.
extension InboxStore {
  // MARK: - La proposition en bandeau

  /// La dernière proposition `suggest` du fil ouvert qui vaut encore : rien
  /// n'est arrivé du correspondant depuis. Elle se rend en bandeau au-dessus
  /// de la saisie, jamais en carte dans le fil.
  var pendingSuggestion: ChatMessage? {
    for message in messages.reversed() {
      if let proposal = message.agentProposal {
        if proposal.kind == .suggest { return message }
        continue
      }
      // Un vrai message est arrivé après : la proposition parlait d'avant.
      if !message.isFromMe, !message.isSystemEvent { return nil }
    }
    return nil
  }

  /// Ce qui périme un bandeau, une fois le fil rechargé : les propositions
  /// `suggest` qu'un message entrant a dépassées s'effacent, localement.
  func dismissStaleSuggestions() {
    let pending = pendingSuggestion?.id
    let stale = messages.filter { $0.agentProposal?.kind == .suggest && $0.id != pending }
    for message in stale { ignoreAgentProposal(message) }
  }

  /// « Répondre » sur un résumé : la saisie prend le focus, vide. La carte
  /// reste — un résumé se relit pendant qu'on répond.
  func requestComposerFocus() {
    composerFocusToken &+= 1
  }

  // MARK: - L'aparté envoyé par un geste

  /// Les agents présents dans le fil ouvert, par leur nom court. Vide hors
  /// d'un fil bridgé : c'est ce qui décide si un geste devient un ordre à cc.
  var agentsInSelectedConversation: [String] {
    primarySession?.asideAgents ?? []
  }

  /// Envoie un aparté à `agent` dans le fil ouvert — un ordre que le
  /// correspondant ne verra pas — par le chemin d'envoi ordinaire : le texte
  /// nomme l'agent, le pont en fait un `AgentWire.asideType`.
  ///
  /// Rend `false` si rien n'est parti (pas de fil, pas d'agent).
  @discardableResult
  func sendAside(_ instruction: String, to agent: String? = nil, inReplyTo messageID: String? = nil) async -> Bool {
    guard let conversation = selectedConversation,
          let nom = agent ?? agentsInSelectedConversation.first
    else { return false }
    let text = "@\(nom) \(instruction)"
    if isDemo {
      // En démonstration, la bulle se pose et rien ne part : on voit le geste.
      let quoted = messageID.flatMap { id in messages.first { $0.id == id } }
      var optimistic = ChatMessage(
        id: "local-\(UUID().uuidString)", conversationID: conversation.id, network: conversation.network,
        text: text, sentAt: .now, isFromMe: true, agentAside: AgentAside(agents: [nom])
      )
      if let quoted {
        optimistic.replyTo = QuotedMessage(
          messageID: quoted.id, senderName: quoted.senderName ?? "", text: quoted.sidebarPreviewText
        )
      }
      primarySession?.messages.append(optimistic)
      return true
    }
    guard conversation.network.livesOnRelay, isMatrixConnected else {
      lastErrorMessage = "Le Relais n’est pas connecté. Va voir dans Réglages, Relais."
      return false
    }
    do {
      try await matrix.send(
        conversationID: conversation.id, text: text, attachmentPaths: [],
        localID: "local-\(UUID().uuidString)", replyToMessageID: messageID
      )
      await loadMessagesForSelection()
      return true
    } catch {
      lastErrorMessage = error.localizedDescription
      return false
    }
  }

  /// « Réessayer » sur un avis de cc : le dernier aparté que j'ai envoyé
  /// dans ce fil repart tel quel.
  func retryLastAside() async {
    guard let last = messages.last(where: { $0.isFromMe && $0.isAgentAside }) else { return }
    let agents = last.agentAside?.agents ?? []
    // Le texte porte déjà « @cc » : on le retire, `sendAside` le remet.
    let stripped = agents.reduce(last.text) { partial, nom in
      partial.replacingOccurrences(of: "@\(nom)", with: "")
    }
    await sendAside(
      stripped.trimmingCharacters(in: .whitespacesAndNewlines),
      to: agents.first, inReplyTo: last.replyTo?.messageID
    )
  }

  /// « Relancer » sur un avis de cc : l'agent rescane sa machine.
  func rescanAgent(named agent: String) async {
    guard let console = await loadAgentConsole(agent: agent) else {
      lastErrorMessage = "la console de \(agent) n'est pas joignable"
      return
    }
    _ = await requestAgentRescan(console)
  }

  // MARK: - Résumer

  /// Le seuil de non-lus à partir duquel « Résumer » apparaît. La maquette
  /// disait quinze ; à cinq, on le voit sur un fil de démonstration.
  static let summaryThreshold = 5
  static let summaryCooldown: TimeInterval = 30

  /// « Résumer » a-t-il sa place dans la barre : assez de non-lus, et un
  /// agent à qui le demander ?
  var offersSummary: Bool {
    guard let conversation = selectedConversation,
          max(conversation.unreadCount, unreadAtSelection) >= Self.summaryThreshold
    else { return false }
    return !agentsInSelectedConversation.isEmpty
  }

  /// Le bouton dort trente secondes après un clic : un tour de cc prend ce temps-là.
  var isSummaryCoolingDown: Bool {
    guard let at = summaryRequestedAt else { return false }
    return Date.now.timeIntervalSince(at) < Self.summaryCooldown
  }

  func requestSummary() async {
    guard offersSummary, !isSummaryCoolingDown else { return }
    let at = Date.now
    summaryRequestedAt = at
    await sendAside(
      "résume les messages non lus de cette conversation : ce qui attend une réponse d'abord, puis le reste en une ligne"
    )
    // Le réveil du bouton : l'écran ne se redessine pas tout seul à l'échéance.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.summaryCooldown))
      guard let self, self.summaryRequestedAt == at else { return }
      self.summaryRequestedAt = nil
    }
  }
}
