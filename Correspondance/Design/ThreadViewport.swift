import SwiftUI

/// Le cadre du fil : ce qu'il répond quand on lui demande sa taille SANS lui
/// en proposer une vraie.
///
/// Mesuré au `sample` sur un groupe Signal de mille messages, pendant un
/// défilement au trackpad : 62 % du fil principal partait dans
/// `NSHostingView.minSize()`. À chaque frame du geste, AppKit refait la passe
/// de contraintes de la fenêtre ; l'hôte SwiftUI y recalcule sa taille
/// minimale (`.windowResizability(.contentMinSize)` en vit), et pour la
/// connaître il propose **zéro** à tout l'arbre. Un `ScrollView` prend sa
/// largeur de son contenu : il remesurait donc les cent cinquante rangées du
/// fil à largeur nulle — chaque `Text` replié mot à mot — et reconstruisait au
/// passage les enfants du `ForEach`, reconnaissance de langue comprise. La
/// taille idéale (`nil × nil`) coûtait la même chose, une fois par passe de
/// layout ; et la pile qui contient le fil sonde encore `largeur × 0` et
/// `largeur × ∞` avant de placer — trois mesures du contenu par passe.
///
/// Un fil n'a ni taille minimale ni taille idéale qui dépende de ses bulles :
/// il prend la place qu'on lui donne, et défile pour le reste. Ce `Layout` le
/// dit sans consulter son enfant. Une dimension absente ou nulle reçoit une
/// constante ; l'infini reste l'infini — c'est ce qu'un `ScrollView` répond,
/// et c'est ce qui fait du fil l'enfant le plus souple de la colonne, celui
/// qui prend tout ce que le composer laisse ; une dimension concrète est
/// rendue telle quelle, comme le ferait le `ScrollView` dont chaque rangée
/// s'étire à la largeur (`.frame(maxWidth: .infinity)`). L'enfant n'est
/// mesuré qu'au placement, à la vraie taille.
///
/// Le placement aussi se garde : la pile de navigation **place** ses enfants
/// pour répondre à une mesure, et la passe « au plus petit » plaçait donc le
/// fil dans ses 240 points de repli — le `ScrollView` remesurait tout son
/// contenu à cette largeur-là (vu au second `sample` : 722 ms sur 5 s, la
/// moitié de ce qu'on venait d'ôter). Une passe sans vraie proposition
/// replace l'enfant à la dernière taille concrète connue : c'est celle qu'il
/// a déjà, et le `ScrollView` n'a rien à recalculer.
struct ThreadViewport: Layout {
  /// Ce que le fil réclame au minimum et propose comme idéal : de quoi tenir
  /// une bulle courte et quelques lignes. La fenêtre détachée descend à
  /// 240 × 180 avec son composer ; le fil seul se contente de moins.
  static let fallbackSize = CGSize(width: 240, height: 120)

  struct Cache {
    /// La dernière taille venue d'une vraie proposition — celle de la fenêtre.
    var lastConcreteSize: CGSize?
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    CGSize(
      width: Self.resolve(proposal.width, fallback: Self.fallbackSize.width),
      height: Self.resolve(proposal.height, fallback: Self.fallbackSize.height)
    )
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let size: CGSize
    if Self.isConcrete(proposal) {
      size = bounds.size
      cache.lastConcreteSize = size
    } else {
      size = cache.lastConcreteSize ?? bounds.size
    }
    for subview in subviews {
      subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
  }

  /// Une proposition qui vient d'une vraie mise en page : deux dimensions,
  /// finies, non nulles. Tout le reste est une mesure.
  static func isConcrete(_ proposal: ProposedViewSize) -> Bool {
    guard let width = proposal.width, let height = proposal.height else { return false }
    return width > 0 && height > 0 && width.isFinite && height.isFinite
  }

  /// `nil` dit « à l'idéal », zéro « au plus petit » : la constante. Tout le
  /// reste — l'infini compris — est rendu tel quel.
  static func resolve(_ proposed: CGFloat?, fallback: CGFloat) -> CGFloat {
    guard let proposed, proposed > 0 else { return fallback }
    return proposed
  }
}
