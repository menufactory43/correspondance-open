import CorrespondanceCore
import Foundation

/// La pièce jointe avec son chemin local retrouvé dans le cache, si elle y est
/// — ce que `MessageBubble.repaired` fait sur l'iPhone.
enum AttachmentRepair {
  static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = MatrixAttachmentStore.existingLocalPath(
      forMXC: attachment.id,
      contentType: attachment.contentType
    ) {
      copy.localPath = path
    }
    return copy
  }
}
