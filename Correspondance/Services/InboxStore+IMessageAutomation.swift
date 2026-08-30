import AppKit
import Foundation
import CorrespondanceCore

/// Lot M2 — le branchement UI de l'automatisation Messages.
/// Tout vit ici pour laisser `InboxStore.swift` quasi intact : ce fichier ne
/// contient que des méthodes, pas d'état (l'état observable reste dans la classe).
extension InboxStore {
  private var automation: IMessageAutomation { IMessageAutomation.shared }

  // MARK: - Réglages et santé

  /// Pousse le réglage vers l'acteur puis relance la sonde. Appelé au lancement
  /// et à chaque bascule dans Réglages.
  func refreshMessagesAutomation() {
    let enabled = isMessagesAutomationEnabled
    let offscreen = messagesAutomationOffscreenWindow
    Task { @MainActor [weak self] in
      guard let self else { return }
      await IMessageAutomation.shared.configure(enabled: enabled, offscreenWindow: offscreen)
      let health = await IMessageAutomation.shared.probe()
      self.setMessagesAutomationHealth(health)
    }
  }

  /// Libellé de l'état de santé pour Réglages.
  var messagesAutomationHealthFR: String {
    messagesAutomationHealth.labelFR()
  }

  /// L'automatisation peut-elle être tentée ? Sert à griser les entrées de menu.
  var canAutomateMessages: Bool {
    isMessagesAutomationEnabled && messagesAutomationHealth.allowsActions
  }

  /// Réglages Système › Confidentialité et sécurité › Accessibilité.
  func openAccessibilityPrivacySettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    ]
    for raw in candidates {
      if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
    }
  }

  // MARK: - Actions

  /// Tapback : pose ou retrait selon ce que je porte déjà sur cette bulle.
  func sendTapbackViaAutomation(conversation: Conversation, message: ChatMessage, emoji: String) async {
    guard let blocker = automationBlocker(for: conversation) else {
      guard let tapback = IMessageTapback.matching(emoji: emoji) else {
        lastErrorMessage = "iMessage n’accepte que ❤️ 👍 👎 😂 ‼️ ❓ en tapback."
        return
      }
      guard let target = automationTarget(conversation: conversation, message: message) else {
        lastErrorMessage = "Message iMessage sans GUID — tapback impossible."
        return
      }
      let removing = message.myReactionEmoji == emoji
      do {
        try await automation.setTapback(tapback, on: target, removing: removing)
        await reloadMessagesAfterAutomation()
      } catch {
        await reportAutomationFailure(error)
      }
      return
    }
    lastErrorMessage = blocker
  }

  /// Réponse citée. `true` si le message est bien parti et confirmé par chat.db.
  func sendQuotedReplyViaAutomation(conversation: Conversation, quotedID: String, text: String) async -> Bool {
    if let blocker = automationBlocker(for: conversation) {
      lastErrorMessage = blocker
      return false
    }
    guard let quoted = messages.first(where: { $0.id == quotedID }),
          let target = automationTarget(conversation: conversation, message: quoted)
    else {
      lastErrorMessage = "Le message cité n’existe plus — réponse annulée."
      return false
    }
    do {
      try await automation.reply(to: target, text: text)
      return true
    } catch {
      await reportAutomationFailure(error)
      return false
    }
  }

  /// Modifier un message envoyé (≤ 15 min côté Messages).
  func editMessageViaAutomation(messageID: String, newText: String) async {
    guard let conversation = selectedConversation,
          let message = messages.first(where: { $0.id == messageID })
    else { return }
    if let blocker = automationBlocker(for: conversation) {
      lastErrorMessage = blocker
      return
    }
    guard message.isFromMe else {
      lastErrorMessage = "On ne modifie que ses propres messages."
      return
    }
    guard let target = automationTarget(conversation: conversation, message: message) else {
      lastErrorMessage = "Message iMessage sans GUID — modification impossible."
      return
    }
    do {
      try await automation.edit(target, newText: newText)
      await reloadMessagesAfterAutomation()
    } catch {
      await reportAutomationFailure(error)
    }
  }

  /// Annuler l'envoi (≤ 2 min côté Messages).
  func undoSendViaAutomation(messageID: String) async {
    guard let conversation = selectedConversation,
          let message = messages.first(where: { $0.id == messageID })
    else { return }
    if let blocker = automationBlocker(for: conversation) {
      lastErrorMessage = blocker
      return
    }
    guard message.isFromMe else {
      lastErrorMessage = "On n’annule que ses propres envois."
      return
    }
    guard let target = automationTarget(conversation: conversation, message: message) else {
      lastErrorMessage = "Message iMessage sans GUID — annulation impossible."
      return
    }
    do {
      try await automation.undoSend(target)
      await reloadMessagesAfterAutomation()
    } catch {
      await reportAutomationFailure(error)
    }
  }

  /// Marquer lu = faire sélectionner le fil par Messages, cachée. Silencieux :
  /// ouvrir un fil ne doit jamais afficher d'erreur si l'automatisation est éteinte.
  func markReadViaAutomation(conversation: Conversation) {
    guard canAutomateMessages,
          let chatGUID = IMessageDatabase.guid(fromConversationID: conversation.id)
    else { return }
    let identifier = conversation.address
    Task { @MainActor [weak self] in
      do {
        try await IMessageAutomation.shared.markRead(chatGUID: chatGUID, chatIdentifier: identifier)
      } catch {
        // Marquer lu est un geste de confort : on note l'échec sans le crier.
        await self?.refreshAutomationHealthOnly()
      }
    }
  }

  /// Marquer non lu : celui-là, l'utilisateur l'a demandé — l'échec se dit.
  func markUnreadViaAutomation(conversation: Conversation) {
    // Réglage éteint : le « non lu » reste local, exactement comme avant M2.
    guard isMessagesAutomationEnabled else { return }
    if let blocker = automationBlocker(for: conversation) {
      lastErrorMessage = blocker
      return
    }
    guard let chatGUID = IMessageDatabase.guid(fromConversationID: conversation.id) else { return }
    let identifier = conversation.address
    Task { @MainActor [weak self] in
      do {
        try await IMessageAutomation.shared.markUnread(chatGUID: chatGUID, chatIdentifier: identifier)
      } catch {
        await self?.reportAutomationFailure(error)
      }
    }
  }

  // MARK: - Outils

  /// Ce qui empêche une action AX sur ce fil, ou `nil`. Jamais d'échec silencieux.
  func automationBlocker(for conversation: Conversation) -> String? {
    guard conversation.network == .iMessage else { return nil }
    guard isMessagesAutomationEnabled else {
      return "Les tapbacks, réponses citées et modifications iMessage passent par "
        + "l’automatisation Messages : active-la dans Réglages → Automatisation Messages."
    }
    if usingDemoData {
      return "Données démo — accorde l’accès disque pour piloter Messages."
    }
    guard messagesAutomationHealth.allowsActions else {
      return messagesAutomationHealth.labelFR()
    }
    return nil
  }

  /// Construit la cible AX à partir de nos identifiants (`imessage:<chat guid>`
  /// et le GUID de message de chat.db).
  func automationTarget(conversation: Conversation, message: ChatMessage) -> IMessageTarget? {
    guard let chatGUID = IMessageDatabase.guid(fromConversationID: conversation.id) else { return nil }
    // Un id de repli `imessage-msg-<rowid>` signifie que chat.db n'avait pas de
    // GUID : sans lui, aucune vérification n'est possible, donc on n'agit pas.
    guard !message.id.hasPrefix("imessage-msg-"), !message.id.isEmpty else { return nil }
    return IMessageTarget(
      chatGUID: chatGUID,
      chatIdentifier: conversation.address,
      messageGUID: message.id,
      messageText: message.text,
      isFromMe: message.isFromMe
    )
  }

  /// Remonte l'erreur à l'UI **et** re-sonde : c'est la règle du plan.
  func reportAutomationFailure(_ error: Error) async {
    lastErrorMessage = error.localizedDescription
    await refreshAutomationHealthOnly()
  }

  func refreshAutomationHealthOnly() async {
    let health = await IMessageAutomation.shared.probe()
    setMessagesAutomationHealth(health)
  }
}
