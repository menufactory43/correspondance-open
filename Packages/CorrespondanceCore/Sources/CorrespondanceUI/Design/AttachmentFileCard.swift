import CorrespondanceCore
import SwiftUI

/// UN FICHIER JOINT qui n'est ni photo, ni vidéo, ni voix : un PDF, une archive,
/// un document. La bulle n'en montrait que le nom, sans rien pouvoir en faire ;
/// la carte dit son type et son poids, et l'ouvre par Quick Look.
public struct AttachmentFileCard: View {
  public let attachment: MessageAttachment
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  /// Ouvrir le fichier. `nil` quand il n'est pas encore sur l'appareil.
  public var onOpen: (() -> Void)?

  public init(
    attachment: MessageAttachment,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    onOpen: (() -> Void)? = nil
  ) {
    self.attachment = attachment
    self.theme = theme
    self.typeface = typeface
    self.onOpen = onOpen
  }

  public var body: some View {
    let card = HStack(spacing: Spacing.xs) {
      Image(systemName: Self.symbol(forPath: name))
        .font(.system(size: 20))
        .foregroundStyle(theme.accent)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(name)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
        if let weight {
          Text(weight)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: 280, alignment: .leading)
    .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([name, weight].compactMap { $0 }.joined(separator: ", "))

    if let onOpen {
      Button(action: onOpen) { card }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre un aperçu du fichier")
    } else {
      card
    }
  }

  private var name: String { attachment.filename ?? "Pièce jointe" }

  private var weight: String? {
    guard let url = attachment.resolvedFileURL,
          let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    else { return nil }
    return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
  }

  /// Icône du type de fichier, à l'extension.
  public static func symbol(forPath path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "pdf": "doc.richtext"
    case "mp4", "mov", "m4v": "film"
    case "caf", "m4a", "mp3", "aac", "wav", "ogg", "opus": "waveform"
    case "zip", "gz", "tar": "doc.zipper"
    default: "doc"
    }
  }
}
