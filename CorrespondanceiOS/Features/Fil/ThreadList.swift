import SwiftUI
import UIKit

/// Le fil, posé sur un `UICollectionView`.
///
/// Pourquoi pas un `ScrollView` + `LazyVStack` : une pile paresseuse ESTIME la
/// hauteur des rangées qu'elle n'a pas mesurées, et SwiftUI recale le décalage
/// tout seul, hors transaction, quand le contenu change de taille. Les deux
/// ensemble donnaient un fil qui s'ouvrait sur du vide, sautait de 80 points à
/// l'envoi, et se garait sous son propre bas dès qu'une bulle se révélait plus
/// petite que son estimation. La parade tenait en deux cents lignes
/// d'arithmétique de rattrapage — trois pilotes concurrents, chacun avec sa
/// fenêtre de temps.
///
/// Signal ne fait pas autrement : sa `ConversationCollectionView` surcharge le
/// setter de `contentOffset` pour EMPÊCHER UIKit de recaler le fil, et place
/// elle-même chaque décalage. C'est ce que fait cette liste — un seul pilote,
/// `place(_:)`, et une règle avant chaque remise en page : soit on est collé
/// au bas et on y reste, soit on tient une rangée sous les yeux et c'est ELLE
/// qui ne bouge pas. Le reste — le dépliage de l'iPhone Duo compris — n'est
/// qu'un cas particulier de la seconde règle.
///
/// Les bulles restent du SwiftUI : `UIHostingConfiguration` pose `content`
/// dans chaque cellule. UIKit ne gagne ici que le défilement.
struct ThreadList<Row: View>: UIViewControllerRepresentable {
  /// Les rangées, dans l'ordre du fil.
  let rows: [ThreadRow]
  /// Ce qui change l'aspect de TOUTES les rangées d'un coup — thème, fonte,
  /// mentions. Quand il bouge, les cellules déjà posées se refont.
  let styleToken: Int
  /// La rangée sur laquelle le fil s'ouvre : la barre des non-lus, ou le bas.
  /// `nil` tant que la vue ne le sait pas — la liste attend alors plutôt que
  /// de se poser en bas et d'avoir à se reprendre.
  let opensOn: ThreadListOpening?
  /// Ce que la liste renvoie à chaque défilement : où l'on en est.
  let onStateChange: (ThreadListState) -> Void
  /// Le haut du fil approche : le Relais a une page de plus à donner.
  let onReachTop: () -> Void
  /// La poignée par laquelle la vue SwiftUI commande le défilement.
  let proxy: ThreadListProxy
  @ViewBuilder let content: (ThreadRow) -> Row

  func makeUIViewController(context: Context) -> ThreadListViewController<Row> {
    let controller = ThreadListViewController<Row>(content: content)
    hand(controller)
    return controller
  }

  func updateUIViewController(_ controller: ThreadListViewController<Row>, context: Context) {
    hand(controller)
  }

  private func hand(_ controller: ThreadListViewController<Row>) {
    controller.content = content
    controller.onStateChange = onStateChange
    controller.onReachTop = onReachTop
    controller.opensOn = opensOn
    proxy.target = controller
    controller.apply(rows: rows, styleToken: styleToken)
  }
}

/// Où poser le fil la première fois qu'il se mesure.
enum ThreadListOpening: Equatable {
  /// Le dernier message, comme toute conversation déjà lue.
  case bottom
  /// La barre des non-lus, posée en haut de l'écran : ce qui attend est
  /// dessous, et l'historique déjà lu ne vole pas la place.
  case unreadMark
}

/// Ce que la vue SwiftUI a besoin de savoir du défilement.
struct ThreadListState: Equatable {
  /// Le bas du fil est sous les yeux : le chevron n'a alors rien à faire.
  var isNearBottom = true
  /// Ce qui attend plus bas : les non-lus de l'ouverture, puis ce qui arrive
  /// pendant qu'on relit plus haut. C'est le nombre porté par le chevron.
  var unreadBelow = 0
}

/// La poignée : ce que la vue SwiftUI sait demander au fil.
@MainActor
final class ThreadListProxy {
  fileprivate weak var target: (any ThreadListCommands)?

  /// Ramène au dernier message.
  func scrollToBottom(animated: Bool = true) { target?.scrollToBottom(animated: animated) }

  /// Va poser un message au centre de l'écran — le saut d'une citation.
  func jump(to messageID: String, animated: Bool = true) {
    target?.jump(to: messageID, animated: animated)
  }

  /// Le prochain message qui s'ajoute est de moi : le fil le suit en glissant
  /// plutôt qu'en recollant sec. C'est le seul moment où il doit se voir bouger.
  func expectOwnSend() { target?.expectOwnSend() }

  /// Le fil tient-il déjà son bas ?
  var isNearBottom: Bool { target?.isNearBottom ?? true }
}

/// Ce que la poignée sait demander, sans rien connaître du type des rangées.
@MainActor
protocol ThreadListCommands: AnyObject {
  func scrollToBottom(animated: Bool)
  func jump(to messageID: String, animated: Bool)
  func expectOwnSend()
  var isNearBottom: Bool { get }
}

/// Le contrôleur : une liste, un pilote de décalage, et rien d'autre.
@MainActor
final class ThreadListViewController<Row: View>: UIViewController, UICollectionViewDelegate,
  ThreadListCommands
{
  var content: (ThreadRow) -> Row
  var onStateChange: (ThreadListState) -> Void = { _ in }
  var onReachTop: () -> Void = {}
  var opensOn: ThreadListOpening?

  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
  private var registration: UICollectionView.CellRegistration<UICollectionViewCell, ThreadRow>!

  private var rows: [ThreadRow] = []
  private var rowsByID: [String: ThreadRow] = [:]
  private var styleToken = 0
  /// Ce qui est arrivé avant que la vue n'existe — `makeUIViewController`
  /// donne les rangées avant le premier `viewDidLoad`.
  private var pending: (rows: [ThreadRow], styleToken: Int)?

  /// Le fil s'est posé une première fois : avant ça, il n'y a rien à tenir.
  private var hasPlacedFirstLayout = false
  /// Vrai tant que le bas du fil est à l'écran.
  private(set) var isNearBottom = true
  /// On a touché le bas depuis l'ouverture : la barre des non-lus ne fait plus
  /// frontière, seul ce qui arrive ensuite compte.
  private var hasReachedBottom = false
  /// La dernière rangée vue alors qu'on était en bas — la frontière de ce
  /// qu'on a laissé derrière soi.
  private var frontierRowID: String?
  /// Jusqu'à quand un ajout se suit en glissant : posé par mes propres envois.
  private var glidesUntil: Date?
  /// La géométrie de la dernière mise en page : de quoi voir un dépliage venir.
  private var lastBounds: CGSize = .zero
  private var lastBottomInset: CGFloat = 0
  /// Ce qu'on tient sous les yeux le temps d'une remise en page.
  private var heldAnchor: Anchor?
  private var reportedState = ThreadListState()
  /// Vrai le temps d'une remise en page : les relevés de défilement qu'elle
  /// provoque décrivent un fil à moitié posé, pas ce que l'œil voit.
  private var isSettling = false

  /// Une rangée, et la distance entre son bord haut et celui de l'écran.
  /// Tenir ce couple constant, c'est ne pas bouger d'un pouce.
  private struct Anchor {
    var id: String
    var offsetFromTop: CGFloat
  }

  init(content: @escaping (ThreadRow) -> Row) {
    self.content = content
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Correspondance ne charge pas de nib.") }

  // MARK: - Mise en place

  override func viewDidLoad() {
    super.viewDidLoad()
    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
    configuration.showsSeparators = false
    configuration.backgroundColor = .clear
    let layout = UICollectionViewCompositionalLayout.list(using: configuration)

    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .interactive
    // Les encarts de la zone sûre — clavier, composer, barre d'onglets —
    // arrivent par SwiftUI et doivent entrer dans le décalage : c'est ce qui
    // pose le dernier message SUR le composer, et non dessous.
    collectionView.contentInsetAdjustmentBehavior = .always
    // Le préchargement pose des cellules hors écran à partir de hauteurs
    // seulement estimées : sur un fil d'images, la hauteur totale bougeait
    // sous le doigt. On ne mesure que ce qu'on montre.
    collectionView.isPrefetchingEnabled = false
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])

    registration = UICollectionView.CellRegistration<UICollectionViewCell, ThreadRow> {
      [weak self] cell, _, row in
      guard let self else { return }
      cell.contentConfiguration = UIHostingConfiguration { self.content(row) }
        .margins(.all, 0)
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    }

    dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
      [weak self] view, indexPath, id in
      guard let self, let row = rowsByID[id] else { return UICollectionViewCell() }
      return view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
    }

    if let pending {
      self.pending = nil
      apply(rows: pending.rows, styleToken: pending.styleToken)
    }
  }

  // MARK: - Les rangées

  func apply(rows next: [ThreadRow], styleToken token: Int) {
    guard isViewLoaded else {
      pending = (next, token)
      return
    }
    let styleChanged = token != styleToken
    styleToken = token
    guard next != rows || styleChanged else { return }

    let previous = rowsByID
    rows = next
    rowsByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // Ce qui existait déjà et n'a fait que changer d'aspect : la cellule se
    // refait sur place, sans que la liste ne joue une insertion.
    let touched: [String] =
      styleChanged
      ? next.map(\.id).filter { previous[$0] != nil }
      : next.compactMap { row in
        guard let old = previous[row.id], old != row else { return nil }
        return row.id
      }

    // Ce qu'on tient : le bas, ou une rangée précise. Relevé AVANT la remise
    // en page — après, les index ont bougé.
    let holdsBottom = isNearBottom
    let anchor = holdsBottom ? nil : currentAnchor()
    let glides = holdsBottom && (glidesUntil.map { Date() < $0 } ?? false)

    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(next.map(\.id))
    if !touched.isEmpty { snapshot.reconfigureItems(touched) }

    // Sans animation et depuis la file principale, la liste se met à jour
    // séquentiellement : le placement qui suit voit déjà la nouvelle mise en
    // page. C'est ce qui permet de n'avoir qu'un seul pilote.
    isSettling = true
    dataSource.apply(snapshot, animatingDifferences: false)
    isSettling = false

    guard hasPlacedFirstLayout else {
      placeOnOpening()
      return
    }
    if holdsBottom {
      place { scrollToBottom(animated: glides) }
    } else if let anchor {
      place { restore(anchor) }
    }
    reportState()
  }

  /// Le premier placement : la barre des non-lus si on en a une, sinon le bas.
  /// Tant que le fil n'a ni rangée, ni hauteur, ni consigne, il n'y a rien à
  /// poser — on repassera à la mise en page suivante.
  private func placeOnOpening() {
    guard !hasPlacedFirstLayout, !rows.isEmpty, view.bounds.height > 0,
      let opensOn
    else { return }
    hasPlacedFirstLayout = true
    place {
      switch opensOn {
      case .bottom:
        scrollToBottom(animated: false)
      case .unreadMark:
        // La barre se pose en HAUT de l'écran : ce qui attend est dessous,
        // d'un coup d'œil. Faute de barre — rien à lire — le bas fait l'affaire.
        if rowsByID[ThreadRows.unreadMarkID] != nil {
          scroll(toRow: ThreadRows.unreadMarkID, at: .top, animated: false)
          // On n'a PAS vu le bas : le chevron doit annoncer ce qui reste.
          hasReachedBottom = false
          isNearBottom = false
        } else {
          scrollToBottom(animated: false)
        }
      }
    }
    reportState()
  }

  // MARK: - Le pilote

  /// Le seul endroit d'où le décalage bouge de lui-même.
  ///
  /// Tout ce qui déplace le fil sans qu'un doigt le demande passe par ici : la
  /// liste est mise à jour avant, et les relevés de défilement provoqués par
  /// le trajet ne sont pas pris pour la position finale.
  private func place(_ body: () -> Void) {
    collectionView.layoutIfNeeded()
    isSettling = true
    body()
    isSettling = false
  }

  func scrollToBottom(animated: Bool) {
    guard let last = rows.last else { return }
    // Viser LA DERNIÈRE RANGÉE, pas un décalage en points : la liste se mesure
    // à mesure, et une hauteur totale encore estimée garerait le fil sous son
    // propre bas — écran vide.
    scroll(toRow: last.id, at: .bottom, animated: animated)
    hasReachedBottom = true
    frontierRowID = last.id
    if animated {
      // Le trajet fini, la dernière rangée est mesurée pour de bon : elle peut
      // avoir déplacé le bas de quelques points.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(340))
        self?.settleAtBottom()
      }
    } else {
      collectionView.layoutIfNeeded()
      settleAtBottom()
    }
  }

  /// Le rattrapage du bas, dans les deux sens : une rangée plus petite que son
  /// estimation garait le fil SOUS son propre bas, écran vide.
  private func settleAtBottom() {
    guard !rows.isEmpty else { return }
    let target = maxOffsetY
    guard abs(target - collectionView.contentOffset.y) > 1 else { return }
    isSettling = true
    collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    isSettling = false
    reportState()
  }

  func jump(to messageID: String, animated: Bool) {
    guard rowsByID[messageID] != nil else { return }
    place { scroll(toRow: messageID, at: .centeredVertically, animated: animated) }
  }

  func expectOwnSend() { glidesUntil = Date().addingTimeInterval(0.6) }

  private func scroll(
    toRow id: String, at position: UICollectionView.ScrollPosition, animated: Bool
  ) {
    guard let indexPath = dataSource.indexPath(for: id) else { return }
    collectionView.scrollToItem(at: indexPath, at: position, animated: animated)
  }

  /// La rangée la plus haute à l'écran, et sa distance au bord.
  private func currentAnchor() -> Anchor? {
    let top = collectionView.contentOffset.y
    let visible = collectionView.indexPathsForVisibleItems
      .compactMap { path -> (id: String, minY: CGFloat)? in
        guard let attributes = collectionView.layoutAttributesForItem(at: path),
          let id = dataSource.itemIdentifier(for: path)
        else { return nil }
        return (id, attributes.frame.minY)
      }
    // Celle qui coupe le bord haut, ou la première en dessous : c'est elle que
    // l'œil tient.
    guard
      let chosen = visible.filter({ $0.minY >= top - 0.5 }).min(by: { $0.minY < $1.minY })
        ?? visible.max(by: { $0.minY < $1.minY })
    else { return nil }
    return Anchor(id: chosen.id, offsetFromTop: chosen.minY - top)
  }

  /// Remet sous les yeux la rangée qu'on tenait, à la même hauteur. C'est ce
  /// qui fait qu'une page d'historique ajoutée au-dessus ne déplace rien.
  private func restore(_ anchor: Anchor) {
    guard let indexPath = dataSource.indexPath(for: anchor.id),
      let attributes = collectionView.layoutAttributesForItem(at: indexPath)
    else { return }
    let target = clamped(attributes.frame.minY - anchor.offsetFromTop)
    guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
    collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
  }

  /// Le décalage du bas : le dernier message posé sur le composer.
  private var maxOffsetY: CGFloat {
    let insets = collectionView.adjustedContentInset
    return max(
      -insets.top,
      collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
  }

  private func clamped(_ y: CGFloat) -> CGFloat {
    min(max(y, -collectionView.adjustedContentInset.top), maxOffsetY)
  }

  // MARK: - La géométrie qui change sous le fil

  /// Le fil change de taille — rotation, multitâche, et sur iPhone Duo un
  /// dépliage en pleine lecture. Ce qu'on lisait ne doit pas s'en aller : on
  /// relève avant, on repose après. Une transition de mise en page n'est pas
  /// une transition d'état.
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    guard hasPlacedFirstLayout, view.bounds.size != lastBounds else { return }
    heldAnchor = isNearBottom ? nil : currentAnchor()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let boundsChanged = view.bounds.size != lastBounds
    lastBounds = view.bounds.size
    defer { lastBottomInset = collectionView.adjustedContentInset.bottom }

    guard hasPlacedFirstLayout else {
      placeOnOpening()
      return
    }
    guard boundsChanged else {
      adjustForInsetChange()
      return
    }
    // La largeur a changé : les bulles se re-mesurent, donc toutes les hauteurs
    // avec. On invalide, on laisse la liste se refaire, et seulement ensuite on
    // repose ce qu'on tenait.
    collectionView.collectionViewLayout.invalidateLayout()
    place {
      collectionView.layoutIfNeeded()
      if isNearBottom {
        scrollToBottom(animated: false)
      } else if let heldAnchor {
        restore(heldAnchor)
      }
    }
    heldAnchor = nil
    reportState()
  }

  /// Le bas se rétrécit — clavier qui s'ouvre, citation ou pièces jointes qui
  /// coiffent le champ. Collé au bas, on y reste ; plus haut, ce qu'on lisait
  /// reste sous les yeux au lieu de passer sous le composer.
  private func adjustForInsetChange() {
    let bottom = collectionView.adjustedContentInset.bottom
    let delta = bottom - lastBottomInset
    guard abs(delta) > 0.5 else { return }
    place {
      if isNearBottom {
        scrollToBottom(animated: false)
      } else if delta > 0 {
        collectionView.setContentOffset(
          CGPoint(x: 0, y: clamped(collectionView.contentOffset.y + delta)), animated: false)
      }
    }
  }

  // MARK: - Ce qu'on relève du défilement

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard hasPlacedFirstLayout, !isSettling else { return }
    reportState()
    // Remonter jusqu'en haut, c'est demander la suite : le Relais complète
    // au-dessus, et la lecture ne bouge pas d'un pouce (cf. `restore`).
    let fromTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    if fromTop <= 400, isScrollable { onReachTop() }
  }

  private var isScrollable: Bool {
    let insets = collectionView.adjustedContentInset
    return collectionView.contentSize.height
      > collectionView.bounds.height - insets.top - insets.bottom
  }

  private func reportState() {
    let nearBottom = !isScrollable || maxOffsetY - collectionView.contentOffset.y <= 60
    isNearBottom = nearBottom
    if nearBottom {
      hasReachedBottom = true
      frontierRowID = rows.last?.id
    }
    let state = ThreadListState(isNearBottom: nearBottom, unreadBelow: unreadBelow())
    guard state != reportedState else { return }
    reportedState = state
    onStateChange(state)
  }

  /// Ce qui attend plus bas, et que le chevron annonce.
  ///
  /// Tant qu'on n'a pas touché le bas, c'est la barre des non-lus qui fait
  /// frontière : le chevron porte le compte des messages non lus, et l'appui
  /// les fait tous défiler d'un coup. Une fois le bas atteint, la frontière
  /// devient la dernière rangée vue — ne reste que ce qui arrive pendant qu'on
  /// relit plus haut.
  private func unreadBelow() -> Int {
    guard !rows.isEmpty else { return 0 }
    let frontier: Int
    if hasReachedBottom {
      guard let seen = frontierRowID, let index = rows.firstIndex(where: { $0.id == seen })
      else { return 0 }
      frontier = index + 1
    } else if let mark = rows.firstIndex(where: { $0.id == ThreadRows.unreadMarkID }) {
      frontier = mark
    } else {
      return 0
    }
    let bottomEdge =
      collectionView.contentOffset.y + collectionView.bounds.height
      - collectionView.adjustedContentInset.bottom + 1
    let lastVisible =
      collectionView.indexPathsForVisibleItems
      .filter { path in
        guard let attributes = collectionView.layoutAttributesForItem(at: path) else { return false }
        return attributes.frame.maxY <= bottomEdge
      }
      .map(\.item).max() ?? -1
    let start = max(frontier, lastVisible + 1)
    guard start < rows.count else { return 0 }
    return rows[start...].filter { $0.message != nil }.count
  }
}
