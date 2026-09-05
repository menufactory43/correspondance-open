import PhotosUI
import SwiftUI
import UIKit

/// Ce qu'un média choisi devient avant d'être joint : un fichier du
/// temporaire, dans un format que les ponts acceptent. Partagé entre le
/// composer et le plateau de la pellicule.
@MainActor
enum AttachmentImport {
  static func photos(_ items: [PhotosPickerItem], into store: RelayStore, conversationID: String) async {
    for item in items {
      guard var data = try? await item.loadTransferable(type: Data.self) else { continue }
      var ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
      // Le HEIC ne passe pas tous les ponts : une photo part en JPEG.
      if ["heic", "heif"].contains(ext.lowercased()),
         let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9)
      {
        data = jpeg
        ext = "jpg"
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).\(ext)")
      guard (try? data.write(to: url)) != nil else { continue }
      store.addAttachment(url.path, conversationID: conversationID)
    }
  }

  /// Un fichier choisi hors du bac à sable arrive sous portée de sécurité :
  /// on le recopie dans le temporaire, sinon l'envoi le trouverait illisible.
  static func files(_ urls: [URL], into store: RelayStore, conversationID: String) {
    for source in urls {
      let scoped = source.startAccessingSecurityScopedResource()
      defer { if scoped { source.stopAccessingSecurityScopedResource() } }
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
      guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { continue }
      store.addAttachment(destination.path, conversationID: conversationID)
    }
  }
}
