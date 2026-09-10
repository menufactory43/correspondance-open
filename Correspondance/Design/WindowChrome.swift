import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Ce que le système ne fournit pas encore : l'apparence claire/sombre suivant
/// le thème d'écriture, et le titre de fenêtre masqué (la barre d'outils native
/// et le fond de fenêtre viennent de `containerBackground`, plus de bricolage).
///
/// LA COUTURE : une barre de titre OPAQUE coupe la sidebar en deux — une bande
/// haute d'une couleur, la sidebar d'une autre, avec une arête nette au milieu.
/// La réparation tient en deux gestes, tous deux natifs : la fenêtre passe en
/// `fullSizeContentView` + titre transparent (le contenu monte SOUS la barre),
/// et la barre d'outils rend son fond (`toolbarBackgroundVisibility(.hidden)`).
/// La sidebar peint alors elle-même, du haut de la fenêtre jusqu'en bas.
struct WindowChromeModifier: ViewModifier {
  let theme: WritingTheme

  func body(content: Content) -> some View {
    content
      .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
      .background(WindowChromeApplicator(isDark: theme.id.prefersDarkChrome))
  }
}

private struct WindowChromeApplicator: NSViewRepresentable {
  let isDark: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.postsFrameChangedNotifications = false
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let dark = isDark
    DispatchQueue.main.async {
      guard let window = nsView.window else { return }
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }
}

/// Le fond de la sidebar, D'UN SEUL TENANT du haut de la fenêtre jusqu'en bas.
///
/// La colonne latérale d'un `NavigationSplitView` pose déjà le matériau
/// « sidebar » du système sur toute la hauteur ; on ne le remplace pas, on le
/// TEINTE. Sous `Reduce Transparency` (ou contraste renforcé) le système peint
/// opaque : on fait pareil, avec la teinte pleine du thème.
struct SidebarSurface: View {
  let theme: WritingTheme

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private var prefersOpaque: Bool {
    reduceTransparency || contrast == .increased
  }

  var body: some View {
    theme.sidebar
      // Assez opaque pour que le thème gagne (une teinte trop légère laisse le
      // matériau système reprendre la main et la sidebar vire au gris), assez
      // translucide pour garder la profondeur du matériau.
      .opacity(prefersOpaque ? 1 : 0.88)
      .ignoresSafeArea()
  }
}

extension View {
  func correspondanceWindowChrome(_ theme: WritingTheme) -> some View {
    modifier(WindowChromeModifier(theme: theme))
  }

  /// Chrome fantôme : la barre d'outils s'efface, et revient sur demande.
  @ViewBuilder
  func correspondanceToolbarVisibility(_ visibility: Visibility) -> some View {
    if #available(macOS 15.0, *) {
      toolbarVisibility(visibility, for: .windowToolbar)
    } else {
      toolbar(visibility, for: .windowToolbar)
    }
  }

  /// « On remonte le fil » — le geste, pas la position. En dessous de macOS 15
  /// la géométrie du défilement n'est pas observable : le survol suffit alors.
  @ViewBuilder
  func onScrollUp(threshold: CGFloat = 4, perform action: @escaping () -> Void) -> some View {
    if #available(macOS 15.0, *) {
      onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
        if new < old - threshold { action() }
      }
    } else {
      self
    }
  }

  /// Le bas du fil, tenu comme Messages le tient : tant qu'on n'a pas remonté,
  /// on y reste — quoi qu'il arrive au contenu. Cf. `KeepScrolledToBottom`.
  /// `threshold` : la distance sous l'ancre qui compte encore comme « en bas »
  /// (la marge basse de la page Focus, par exemple).
  @ViewBuilder
  /// `isScrolling`, s'il est donné, suit le geste du lecteur : vrai du premier
  /// mouvement à la fin de l'inertie. Ce qui permet au fil de se rendre
  /// insensible au survol pendant ce temps — cf. `ThreadView`.
  /// `onGeometry`, s'il est donné, reçoit la géométrie du défilement à chaque
  /// mouvement et à chaque arrêt : c'est par là que le fil sait s'il est trop
  /// court pour l'écran, ou que le lecteur touche le haut — cf. `ThreadView`.
  func keepScrolledToBottom(
    threshold: CGFloat = 24,
    isNearBottom: Binding<Bool>,
    isScrolling: Binding<Bool>? = nil,
    onGeometry: ((ThreadScrollProbe) -> Void)? = nil,
    keepBottom: @escaping () -> Void
  ) -> some View {
    if #available(macOS 15.0, *) {
      modifier(KeepScrolledToBottom(
        threshold: threshold, isNearBottom: isNearBottom, isScrolling: isScrolling,
        onGeometry: onGeometry, keepBottom: keepBottom
      ))
    } else {
      // Rien d'observable ici : on retient le bas à chaque changement de hauteur.
      background {
        GeometryReader { geometry in
          Color.clear.onChange(of: geometry.size.height) { _, _ in keepBottom() }
        }
      }
    }
  }

  /// Barre d'outils SANS fond : c'est elle qui créait la bande cousue en haut.
  @ViewBuilder
  func correspondanceTransparentToolbar() -> some View {
    if #available(macOS 15.0, *) {
      toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      toolbarBackground(.hidden, for: .windowToolbar)
    }
  }
}

/// `defaultScrollAnchor(.bottom)` ne suit ni une hauteur qui change sans que
/// le nombre de lignes bouge (réaction sous une bulle, citation que la sync
/// complète, aperçu, image), ni un inset qui se stabilise après la première
/// passe (la barre d'outils) : dans les deux cas le bas glissait de quelques
/// lignes. Ici, dès que la géométrie bouge HORS d'un défilement du lecteur et
/// qu'on n'est plus en bas, on y retourne — sans animer.
///
/// « Suis-je en bas ? » ne se relit qu'à la fin d'un défilement du lecteur :
/// les mouvements programmés (les nôtres, ceux de SwiftUI) ne décrochent jamais
/// l'ancre. Remonter d'un cran la libère ; revenir en bas la reprend.
@available(macOS 15.0, *)
private struct KeepScrolledToBottom: ViewModifier {
  let threshold: CGFloat
  @Binding var isNearBottom: Bool
  var isScrolling: Binding<Bool>?
  var onGeometry: ((ThreadScrollProbe) -> Void)?
  let keepBottom: () -> Void

  @State private var isReaderScrolling = false
  /// La géométrie sur laquelle on a déjà tenté un recalage : ne pas insister
  /// au même endroit, sinon un bas inatteignable ferait boucler.
  @State private var lastAttempt: ScrollBottomProbe?
  /// `scrollTo(id, anchor: .bottom)` aligne sur le bas de la zone HORS insets
  /// (barre d'outils, marges) et s'arrête donc toujours un peu trop haut ;
  /// `scrollTo(edge:)` vise le bord réel du contenu — celui que
  /// `defaultScrollAnchor(.bottom)` atteint au premier affichage.
  ///
  /// Une boîte, pas un `@State ScrollPosition` : SwiftUI ÉCRIT dans ce binding
  /// à chaque frame du défilement, et chaque écriture dans un `@State` d'ici
  /// invalidait le fil entier — les cent cinquante rangées d'un groupe
  /// remesurées trois fois par frame (rendu, taille minimale de l'hôte,
  /// alignement des overlays), 93 % du fil principal, des frames sautées.
  /// Mesuré au `sample` sur un groupe Signal. La boîte absorbe les écritures
  /// sans rien invalider ; `scrollRequest` fait relire la position quand
  /// c'est NOUS qui demandons un défilement.
  @State private var position = ScrollPositionBox()
  @State private var scrollRequest = 0

  func body(content: Content) -> some View {
    content
      .scrollPosition(position.binding(request: scrollRequest))
      .onScrollGeometryChange(for: ScrollBottomProbe.self) { geometry in
        // Le viewport est plus haut que `containerSize` : la bande sous la barre
        // d'outils (inset haut) en fait partie. Sans elle, le vrai bas paraît
        // toujours à 68 px du bas.
        ScrollBottomProbe(
          content: geometry.contentSize.height,
          visibleBottom: geometry.contentOffset.y + geometry.containerSize.height + geometry.contentInsets.top,
          contentBottom: geometry.contentSize.height + geometry.contentInsets.bottom,
          viewport: geometry.containerSize.height + geometry.contentInsets.top,
          top: geometry.contentOffset.y + geometry.contentInsets.top
        )
      } action: { old, new in
        onGeometry?(ThreadScrollProbe(content: new.content, viewport: new.viewport, top: new.top, idle: false))
        guard isNearBottom, !isReaderScrolling else { return }
        let drifted = new.visibleBottom < new.contentBottom - threshold
        guard new.content != old.content || drifted else { return }
        guard new != lastAttempt else { return }
        lastAttempt = new
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          position.value.scrollTo(edge: .bottom)
          scrollRequest &+= 1
        }
      }
      .onScrollPhaseChange { _, newPhase, context in
        isReaderScrolling = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
        // Les bulles lisent ce drapeau : pas de rangée de survol pendant le geste.
        ThreadScrolling.isActive = isReaderScrolling
        if let isScrolling, isScrolling.wrappedValue != isReaderScrolling {
          isScrolling.wrappedValue = isReaderScrolling
        }
        guard newPhase == .idle else { return }
        let geometry = context.geometry
        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height + geometry.contentInsets.top
        let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
        isNearBottom = visibleBottom >= contentBottom - threshold
        onGeometry?(ThreadScrollProbe(
          content: geometry.contentSize.height,
          viewport: geometry.containerSize.height + geometry.contentInsets.top,
          top: geometry.contentOffset.y + geometry.contentInsets.top,
          idle: true
        ))
      }
  }
}

/// Ce que le fil apprend du défilement : la hauteur de ce qui est monté, celle
/// de la fenêtre qui le montre, et la distance déjà remontée depuis le haut
/// (zéro : le lecteur est tout en haut). `idle` : le geste est fini.
struct ThreadScrollProbe: Equatable {
  var content: CGFloat
  var viewport: CGFloat
  var top: CGFloat
  var idle: Bool
}

/// La position de défilement tenue HORS du graphe de vues — cf. `KeepScrolledToBottom`.
@available(macOS 15.0, *)
@MainActor
private final class ScrollPositionBox {
  var value = ScrollPosition()

  /// `request` n'est pas lu : il est là pour que le corps du modificateur
  /// dépende de `scrollRequest`, et relise donc la position après un `scrollTo`.
  func binding(request: Int) -> Binding<ScrollPosition> {
    Binding(get: { self.value }, set: { self.value = $0 })
  }
}

/// Le fil est en train de défiler sous le doigt (ou en décélération). Les
/// bulles s'en servent pour ne pas allumer leur rangée de survol quand c'est
/// le contenu qui passe sous un curseur immobile : chaque allumage (un menu
/// AppKit, un popover, une animation de 120 ms) invalidait la mise en page de
/// tout le fil, et un groupe aux messages courts en faisait passer dix par
/// seconde. Messages et Signal n'allument rien non plus pendant le geste.
@MainActor
enum ThreadScrolling {
  static var isActive = false
}

private struct ScrollBottomProbe: Equatable {
  var content: CGFloat
  var visibleBottom: CGFloat
  var contentBottom: CGFloat
  var viewport: CGFloat
  var top: CGFloat
}

/// Bouton d’outil discret, style Apple / Claude.
struct SoftToolButton: View {
  let systemImage: String
  var title: String? = nil
  var helpText: String
  var isEmphasized: Bool = false
  var isDisabled: Bool = false
  let action: () -> Void

  @Environment(ThemePreferences.self) private var themes
  @State private var hovered = false

  private var theme: WritingTheme { themes.theme }

  private var foreground: Color {
    if isDisabled { return theme.inkTertiary.opacity(0.45) }
    if isEmphasized { return theme.accent }
    return theme.inkSecondary
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
        if let title {
          Text(title)
            .font(.system(size: 12, weight: isEmphasized ? .semibold : .medium))
        }
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, title == nil ? 0 : 8)
      .frame(minWidth: title == nil ? 28 : nil, minHeight: 28)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            hovered && !isDisabled
              ? theme.selection.opacity(0.85)
              : (isEmphasized ? theme.selection.opacity(0.55) : Color.clear)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(helpText)
    .accessibilityLabel(title ?? helpText)
    .onHover { hovered = $0 }
  }
}
