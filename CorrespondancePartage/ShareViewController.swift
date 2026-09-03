import AppKit
import CorrespondanceCore
import SwiftUI

/// L'hôte de la feuille de partage sur Mac : Finder, Safari, Photos, Aperçu.
///
/// Une extension Mac vit dans le bac à sable, obligatoirement. Elle ne peut
/// donc ni piloter Messages ni lire le Trousseau de l'app : elle **dépose**
/// dans le conteneur du groupe et réveille l'app par `correspondance://partage`
/// — voir `Partage.Voie`. C'est le pont que Beeper Desktop, en Electron, ne
/// peut pas construire.
final class ShareViewController: NSViewController {
  private let modele = PartageModele()

  override func loadView() {
    let racine = PartageVue(
      modele: modele,
      annuler: { [weak self] in self?.fermer(annule: true) },
      terminer: { [weak self] in self?.fermer(annule: false) }
    )
    let hote = NSHostingView(rootView: racine)
    hote.frame = NSRect(x: 0, y: 0, width: 440, height: 560)
    view = hote
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    Task { await modele.charger(items, preselection: nil) }
  }

  private func fermer(annule: Bool) {
    modele.nettoyer()
    if annule {
      extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: [])
      }
    }
  }
}
