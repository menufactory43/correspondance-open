import SwiftUI
import UIKit

/// La prise de vue — le seul endroit de l'app iOS où SwiftUI n'a rien à offrir.
///
/// `PhotosPicker` couvre la photothèque, `fileImporter` les fichiers ; prendre
/// une photo passe encore par `UIImagePickerController`. On l'enveloppe une
/// fois, ici, et le composer ne voit qu'une vue SwiftUI qui rend un fichier.
struct CameraCapture: UIViewControllerRepresentable {
  /// Rend le fichier écrit dans le temporaire, ou `nil` si on a renoncé.
  let onCapture: (URL?) -> Void

  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onCapture: onCapture, dismiss: { dismiss() })
  }

  @MainActor
  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onCapture: (URL?) -> Void
    private let dismiss: () -> Void

    init(onCapture: @escaping (URL?) -> Void, dismiss: @escaping () -> Void) {
      self.onCapture = onCapture
      self.dismiss = dismiss
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      defer { dismiss() }
      guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: 0.9)
      else {
        onCapture(nil)
        return
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).jpg")
      onCapture((try? data.write(to: url)) == nil ? nil : url)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onCapture(nil)
      dismiss()
    }
  }
}
