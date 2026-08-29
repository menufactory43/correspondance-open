import Foundation

/// Où vit le nom de l'expéditeur : dans l'aperçu de la liste, jamais dans le
/// corps du message.
///
/// Le parseur Signal collait autrefois « Nom : » en tête du corps de chaque
/// message de groupe. C'était la seule façon de savoir qui parlait, mais ça
/// polluait le texte : impossible de copier une phrase propre, et le fil
/// répétait le nom sous chaque bulle. Le nom vit maintenant à part
/// (`ChatMessage.senderName`) — sauf dans l'aperçu de la liste, où l'on veut
/// savoir qui parle sans ouvrir le fil.
enum SenderPrefix {
  /// Longueur maximale d'un nom d'expéditeur reconnaissable en tête de corps.
  private static let maxSenderLength = 40

  /// « Nom : corps » en groupe, le corps nu en tête-à-tête.
  static func previewLine(_ body: String, senderName: String?, isGroup: Bool) -> String {
    guard isGroup, let senderName, !senderName.isEmpty, !body.isEmpty else { return body }
    return "\(senderName): \(body)"
  }

  /// Sépare un « Nom : corps » écrit par l'ancien parseur Signal, pour les
  /// messages déjà en cache. On reste strict — un nom sans deux-points, sans barre
  /// oblique, sans saut de ligne, et court — pour ne pas découper « Note : ceci »
  /// ou une URL en deux.
  static func splittingLegacySenderPrefix(_ text: String) -> (senderName: String, body: String)? {
    guard let separator = text.range(of: ": ") else { return nil }
    let name = String(text[text.startIndex..<separator.lowerBound])
    let body = String(text[separator.upperBound...])

    guard !name.isEmpty, name.count <= maxSenderLength, !body.isEmpty else { return nil }
    guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    guard !name.contains(where: { $0 == ":" || $0 == "/" || $0.isNewline }) else { return nil }
    return (name, body)
  }
}
