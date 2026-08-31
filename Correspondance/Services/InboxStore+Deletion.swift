import Foundation
import CorrespondanceCore

/// Supprimer un message — parité Beeper (`Delete for Everyone` / `Delete for Me`).
///
/// Deux gestes, jamais confondus : **pour tout le monde** part sur le réseau
/// (une redaction Matrix, que les ponts traduisent en suppression WhatsApp /
/// Signal / Instagram) ; **ici** ne quitte pas la machine — l'identifiant rejoint
/// `HiddenMessageStore` et le fil cesse de le montrer, sur tous les réseaux.
extension InboxStore {
  /// Ce message peut-il partir du réseau lui-même ?
  ///
  /// Seulement les miens, et seulement sur les fils bridgés : Messages n'expose
  /// aucune suppression, ni en AppleScript ni en Accessibilité — pour un
  /// iMessage, « Annuler l'envoi » (≤ 2 min) est le seul retrait qui existe.
  func canDeleteEverywhere(_ message: ChatMessage) -> Bool {
    guard message.isFromMe, !message.isPending, !message.isSystemEvent else { return false }
    guard let conversation = conversation(ofMessage: message) else { return false }
    switch conversation.network {
    case .iMessage: return false
    // La note à soi n'a personne d'autre : « pour tout le monde », c'est moi.
    case .signal, .whatsapp, .instagram, .selfNote: return isMatrixConnected
    }
  }

  /// Ce qui empêche la suppression réseau, pour le dire plutôt que de griser sans raison.
  func deleteEverywhereBlocker(for message: ChatMessage) -> String? {
    guard let conversation = conversation(ofMessage: message) else {
      return "Ce message n’appartient à aucun fil connu."
    }
    if conversation.network == .iMessage {
      return "Messages ne sait pas supprimer un message envoyé — seulement annuler "
        + "l’envoi dans les deux minutes. Ici, il ne disparaîtra que de Correspondance."
    }
    if !isMatrixConnected {
      return "Matrix n’est pas connecté — vérifie Réglages → Matrix."
    }
    if !message.isFromMe {
      return "On ne supprime pour tout le monde que ses propres messages."
    }
    return nil
  }

  /// « Supprimer pour tout le monde » : redaction sur le salon du message.
  /// Le fil se recharge derrière — le `/sync` confirmera dans la seconde.
  func deleteEverywhere(messageID: String) async {
    guard let message = messages.first(where: { $0.id == messageID }),
          // Sur un fil fusionné, la suppression part sur le réseau de la bulle
          // visée — pas sur celui où l'on écrit en ce moment.
          let conversation = conversation(ofMessage: message)
    else { return }
    if let blocker = deleteEverywhereBlocker(for: message) {
      lastErrorMessage = blocker
      return
    }
    do {
      try await matrix.deleteMessage(conversationID: conversation.id, messageID: messageID)
      forgetDeletedMessage(messageID)
      await loadMessagesForSelection()
      refreshPreviewAfterDeletion()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  /// « Supprimer ici » : le message reste chez l'autre, il quitte notre fil.
  /// Persisté, donc réappliqué à chaque relecture — comme l'archivage.
  func deleteLocally(messageID: String) {
    guard !messageID.isEmpty else { return }
    var ids = hiddenMessageIDs
    ids.insert(messageID)
    // Le salon du message : sur un fil bridgé, le masquage rejoint le Relais,
    // pour que l'iPhone ne remontre pas la bulle qu'on vient de retirer ici.
    let conversationID = messages.first { $0.id == messageID }
      .flatMap { conversation(ofMessage: $0) }?.id
    setHiddenMessageIDs(ids, hiddenIn: conversationID)
    forgetDeletedMessage(messageID)
    messages = HiddenMessageStore.visible(messages, hiddenIDs: ids)
    refreshPreviewAfterDeletion()
  }

  /// Ce qui pointait vers la bulle disparue n'a plus lieu d'être : la sélection,
  /// la citation en cours, et le curseur de recherche du fil.
  private func forgetDeletedMessage(_ messageID: String) {
    if selectedMessageID == messageID { selectMessage(nil) }
    if replyingToMessageID == messageID { cancelReply() }
  }

  /// La ligne de l'inbox résumait peut-être le message qu'on vient de retirer.
  private func refreshPreviewAfterDeletion() {
    guard let id = selectedConversationID else { return }
    applySidebarPreview(conversationID: id, from: messages)
    refreshThreadSearchMatches()
  }
}
