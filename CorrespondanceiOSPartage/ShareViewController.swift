import CorrespondanceCore
import Intents
import SwiftUI
import UIKit

/// L'hôte de la feuille de partage sur iPhone : une vue SwiftUI, et le
/// contrat de l'extension — lire les items, rendre la main au système.
///
/// Le contact suggéré en haut de la feuille (la rangée des visages) vient des
/// `INSendMessageIntent` que l'app donne à chaque notification de
/// conversation : quand on tape l'un d'eux, le système nous tend l'intention
/// et son `conversationIdentifier`, qu'on présélectionne.
final class ShareViewController: UIViewController {
  private let modele = PartageModele()

  override func viewDidLoad() {
    super.viewDidLoad()
    let racine = PartageVue(
      modele: modele,
      annuler: { [weak self] in self?.fermer(annule: true) },
      terminer: { [weak self] in self?.fermer(annule: false) }
    )
    let hote = UIHostingController(rootView: racine)
    addChild(hote)
    hote.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hote.view)
    NSLayoutConstraint.activate([
      hote.view.topAnchor.constraint(equalTo: view.topAnchor),
      hote.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hote.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hote.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    didMove(toParent: self)

    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let intention = extensionContext?.intent as? INSendMessageIntent
    Task { await modele.charger(items, preselection: intention?.conversationIdentifier) }
  }

  private func fermer(annule: Bool) {
    modele.nettoyer()
    if annule {
      extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    } else {
      // Un instant pour lire « Envoyé », puis la feuille se replie.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil)
      }
    }
  }
}
