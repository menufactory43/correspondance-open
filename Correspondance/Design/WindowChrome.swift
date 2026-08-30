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
  func keepScrolledToBottom(
    threshold: CGFloat = 24,
    isNearBottom: Binding<Bool>,
    keepBottom: @escaping () -> Void
  ) -> some View {
    if #available(macOS 15.0, *) {
      modifier(KeepScrolledToBottom(threshold: threshold, isNearBottom: isNearBottom, keepBottom: keepBottom))
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
  let keepBottom: () -> Void

  @State private var isReaderScrolling = false
  /// La géométrie sur laquelle on a déjà tenté un recalage : ne pas insister
  /// au même endroit, sinon un bas inatteignable ferait boucler.
  @State private var lastAttempt: ScrollBottomProbe?
  /// `scrollTo(id, anchor: .bottom)` aligne sur le bas de la zone HORS insets
  /// (barre d'outils, marges) et s'arrête donc toujours un peu trop haut ;
  /// `scrollTo(edge:)` vise le bord réel du contenu — celui que
  /// `defaultScrollAnchor(.bottom)` atteint au premier affichage.
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: ScrollBottomProbe.self) { geometry in
        // Le viewport est plus haut que `containerSize` : la bande sous la barre
        // d'outils (inset haut) en fait partie. Sans elle, le vrai bas paraît
        // toujours à 68 px du bas.
        ScrollBottomProbe(
          content: geometry.contentSize.height,
          visibleBottom: geometry.contentOffset.y + geometry.containerSize.height + geometry.contentInsets.top,
          contentBottom: geometry.contentSize.height + geometry.contentInsets.bottom
        )
      } action: { old, new in
        guard isNearBottom, !isReaderScrolling else { return }
        let drifted = new.visibleBottom < new.contentBottom - threshold
        guard new.content != old.content || drifted else { return }
        guard new != lastAttempt else { return }
        lastAttempt = new
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
      }
      .onScrollPhaseChange { _, newPhase, context in
        isReaderScrolling = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
        guard newPhase == .idle else { return }
        let geometry = context.geometry
        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height + geometry.contentInsets.top
        let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
        isNearBottom = visibleBottom >= contentBottom - threshold
      }
  }
}

private struct ScrollBottomProbe: Equatable {
  var content: CGFloat
  var visibleBottom: CGFloat
  var contentBottom: CGFloat
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
