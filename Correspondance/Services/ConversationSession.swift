import Foundation
import Observation

/// Une conversation ouverte, et tout ce qui n'appartient qu'à elle : le fil
/// chargé, le brouillon en cours, les pièces jointes en attente, l'état d'envoi,
/// la bulle visée.
///
/// L'inbox en tient une — celle du fil sélectionné ; chaque fenêtre détachée
/// tient la sienne. Deux vues du MÊME fil partagent la même session, distribuée
/// par `InboxStore.session(for:)` : un message qui arrive se pose une seule
/// fois, et les deux pages le lisent au même instant.
@MainActor
@Observable
final class ConversationSession {
  nonisolated let conversationID: String

  var messages: [ChatMessage] = []

  var draftText: String = "" {
    didSet { captureDraft() }
  }

  /// Chemins locaux des fichiers à envoyer avec le prochain message.
  var pendingAttachmentPaths: [String] = [] {
    didSet { captureDraft() }
  }

  var isSending = false

  /// Bulle visée par les actions du fil (réagir, citer). `nil` = le dernier message.
  var selectedMessageID: String?

  /// Message que le brouillon en cours cite (⌘R). `nil` = réponse simple.
  var replyingToMessageID: String?

  /// Le magasin garde ses sessions ; une session ne fait que lui rendre son
  /// brouillon. La référence est faible pour que la boucle ne se referme pas.
  @ObservationIgnored weak var store: InboxStore?

  /// Vrai le temps de réinstaller un brouillon venu du disque : il ne doit pas
  /// repartir aussitôt vers le disque.
  @ObservationIgnored private var isRestoringDraft = false

  init(conversationID: String, store: InboxStore? = nil) {
    self.conversationID = conversationID
    self.store = store
  }

  /// Le brouillon tel qu'on le range : texte et pièces jointes, rien d'autre.
  var draft: DraftStore.Draft {
    DraftStore.Draft(text: draftText, attachmentPaths: pendingAttachmentPaths)
  }

  var hasDraft: Bool { !draft.isEmpty }

  /// Y a-t-il de quoi envoyer ? Une pièce jointe seule suffit.
  var canSend: Bool {
    !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !pendingAttachmentPaths.isEmpty
  }

  /// La citation affichée au-dessus du composer, s'il y en a une.
  var replyingToMessage: ChatMessage? {
    guard let replyingToMessageID else { return nil }
    return messages.first { $0.id == replyingToMessageID }
  }

  /// La bulle que visent ⌘R et la réaction rapide : celle qu'on a désignée,
  /// sinon la dernière du fil.
  var actionableMessage: ChatMessage? {
    if let selectedMessageID, let found = messages.first(where: { $0.id == selectedMessageID }) {
      return found
    }
    return messages.last(where: \.hasVisibleBody)
  }

  /// Réinstalle un brouillon sans le renvoyer au disque — c'est de là qu'il vient.
  func installDraft(_ draft: DraftStore.Draft) {
    isRestoringDraft = true
    draftText = draft.text
    pendingAttachmentPaths = draft.attachmentPaths
    isRestoringDraft = false
  }

  func clearDraft() {
    installDraft(DraftStore.Draft())
  }

  private func captureDraft() {
    guard !isRestoringDraft else { return }
    store?.captureDraft(from: self)
  }
}
