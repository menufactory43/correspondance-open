import Foundation

struct MessageAttachment: Identifiable, Hashable, Codable, Sendable {
  var id: String
  var contentType: String
  var filename: String?
  /// Chemin local une fois téléchargé par signal-cli.
  var localPath: String?

  var isImage: Bool {
    if contentType.hasPrefix("image/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? id.split(separator: ".").last.map(String.init)
      ?? "").lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext)
  }

  var isVideo: Bool {
    if contentType.hasPrefix("video/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? "").lowercased()
    return ["mp4", "mov", "m4v"].contains(ext)
  }

  var resolvedFileURL: URL? {
    guard let localPath, !localPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: localPath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
  let id: String
  let conversationID: String
  let network: MessageNetwork
  let text: String
  let sentAt: Date
  let isFromMe: Bool
  var isPending: Bool
  var attachments: [MessageAttachment]

  init(
    id: String,
    conversationID: String,
    network: MessageNetwork,
    text: String,
    sentAt: Date,
    isFromMe: Bool,
    isPending: Bool = false,
    attachments: [MessageAttachment] = []
  ) {
    self.id = id
    self.conversationID = conversationID
    self.network = network
    self.text = text
    self.sentAt = sentAt
    self.isFromMe = isFromMe
    self.isPending = isPending
    self.attachments = attachments
  }

  var sidebarPreviewText: String {
    if !text.isEmpty { return text }
    if attachments.contains(where: \.isImage) { return "📷 Photo" }
    if !attachments.isEmpty { return "Pièce jointe" }
    return text
  }

  var hasVisibleBody: Bool {
    !text.isEmpty || !attachments.isEmpty
  }
}
