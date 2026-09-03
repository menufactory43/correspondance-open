import CorrespondanceCore
import Foundation

/// « Envoyer plus tard », et sa limite, dite franchement.
///
/// Sur Mac comme ici, l'envoi part quand l'app est **au premier plan** à
/// l'heure dite. iOS ne donne aucune garantie d'exécution en arrière-plan pour
/// ça — pas de tâche périodique fiable, pas de réveil sur horloge. Beeper vit
/// avec la même limite et la dit ; on la dit aussi, à l'écran, sous le
/// sélecteur : « Part quand l'app est ouverte à l'heure dite. »
///
/// Le mensonge serait de laisser croire à un envoi garanti et de le rater.
extension RelayStore {
  // MARK: - Programmer

  /// Programme ce que le composer contient, et le vide. Le brouillon devient un
  /// message en attente : il n'a plus rien à faire dans le champ.
  func scheduleDraft(
    conversationID: String,
    at date: Date,
    onlyIfNoReply: Bool
  ) {
    let text = draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
    let paths = attachments(conversationID)
    guard !text.isEmpty || !paths.isEmpty else { return }

    scheduled.append(
      ScheduledMessage(
        conversationID: conversationID,
        text: text,
        attachmentPaths: paths,
        replyToMessageID: replyTargets[conversationID],
        sendAt: date,
        onlyIfNoReply: onlyIfNoReply
      )
    )
    saveScheduled()

    setDraft("", conversationID: conversationID)
    for path in paths { removeAttachment(path, conversationID: conversationID) }
    setReplyTarget(nil, conversationID: conversationID)
  }

  func cancelScheduled(_ id: String) {
    scheduled.removeAll { $0.id == id }
    saveScheduled()
  }

  /// Remet le message dans le composer : le corriger, c'est le réécrire.
  func editScheduled(_ id: String) {
    guard let message = scheduled.first(where: { $0.id == id }) else { return }
    setDraft(message.text, conversationID: message.conversationID)
    for path in message.attachmentPaths {
      addAttachment(path, conversationID: message.conversationID)
    }
    cancelScheduled(id)
    selectedConversationID = message.conversationID
  }

  func reschedule(_ id: String, at date: Date) {
    guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
    scheduled[index].sendAt = date
    scheduled[index].lastError = nil
    saveScheduled()
  }

  func scheduledMessages(for conversationID: String) -> [ScheduledMessage] {
    scheduled.filter { $0.conversationID == conversationID }
  }

  func saveScheduled() {
    scheduled = ScheduledMessageStore.sanitized(scheduled)
    ScheduledMessageStore.save(scheduled)
  }

  // MARK: - Envoyer à l'heure dite

  /// Envoie ce qui est dû. Appelé au lancement et à chaque minute pendant que
  /// l'app est visible — jamais autrement, et c'est tout le contrat.
  func flushDueScheduledMessages(now: Date = .now) async {
    let due = scheduled.filter { $0.isDue(at: now) }
    guard !due.isEmpty else { return }

    for message in due {
      // Relance conditionnelle : si l'autre a parlé depuis, elle n'a plus lieu
      // d'être. Elle s'efface, sans rien envoyer et sans rien dire.
      if message.onlyIfNoReply, hasIncomingMessage(in: message.conversationID, since: message.createdAt) {
        scheduled.removeAll { $0.id == message.id }
        continue
      }
      guard conversation(message.conversationID) != nil else {
        // Le fil a disparu du Relais : on ne devine pas où envoyer.
        markScheduled(message.id, error: "Conversation introuvable")
        continue
      }
      let sent = await sendScheduled(message)
      if sent { scheduled.removeAll { $0.id == message.id } }
    }
    saveScheduled()
  }

  private func hasIncomingMessage(in conversationID: String, since date: Date) -> Bool {
    visibleMessages(conversationID).contains { !$0.isFromMe && $0.sentAt > date }
  }

  private func markScheduled(_ id: String, error: String) {
    guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
    scheduled[index].lastError = error
    // Repoussé de cinq minutes : réessayer en boucle chaque seconde ne
    // réparerait rien et noierait le journal.
    scheduled[index].sendAt = Date().addingTimeInterval(300)
  }

  /// Passe par le composer plutôt que par le transport : on veut la bulle
  /// optimiste, la file d'écriture, et l'erreur remise dans le champ — tout ce
  /// que `send` sait déjà faire.
  private func sendScheduled(_ message: ScheduledMessage) async -> Bool {
    let previousDraft = draftText(message.conversationID)
    let previousAttachments = attachments(message.conversationID)

    setDraft(message.text, conversationID: message.conversationID)
    for path in message.attachmentPaths {
      addAttachment(path, conversationID: message.conversationID)
    }
    if let replyID = message.replyToMessageID {
      setReplyTarget(replyID, conversationID: message.conversationID)
    }
    await send(conversationID: message.conversationID)

    // `send` vide le champ quand il réussit et le remplit à nouveau quand il
    // échoue : c'est à ça qu'on reconnaît le verdict, sans le lui demander.
    let stillThere = !draftText(message.conversationID)
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if stillThere {
      markScheduled(message.id, error: syncError ?? "Envoi refusé par le Relais")
      setDraft(previousDraft, conversationID: message.conversationID)
      for path in previousAttachments {
        addAttachment(path, conversationID: message.conversationID)
      }
      return false
    }
    setDraft(previousDraft, conversationID: message.conversationID)
    for path in previousAttachments {
      addAttachment(path, conversationID: message.conversationID)
    }
    return true
  }
}
