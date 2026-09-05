import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Une conversation posée à côté d'un document — Focus, mais dans sa fenêtre.
///
/// Ni liste, ni rail : ce serait une seconde inbox. Un entête d'une ligne, le
/// fil, le composer, et une barre d'outils fantôme qui ne paraît qu'au survol
/// du haut. La fenêtre doit rester lisible jusqu'au format post-it : les marges
/// se serrent avec elle (`FocusPageMetrics`), l'entête se tronque, et le
/// composer ne quitte jamais le bas de la page.
struct DetachedConversationWindow: View {
  /// `nil` = fenêtre sans conversation (restauration système) : elle se ferme.
  let conversationID: String?

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var isChromeRevealed = false
  @State private var hideChromeTask: Task<Void, Never>?
  @State private var isShowingInfo = false

  /// Taille minimale réelle de la fenêtre : un post-it où tout tient encore.
  static let minimumSize = CGSize(width: 240, height: 180)

  private var theme: WritingTheme { themes.theme }

  private var session: ConversationSession? {
    conversationID.map { store.session(for: $0) }
  }

  private var conversation: Conversation? {
    conversationID.flatMap { store.conversationRow($0) }
  }

  var body: some View {
    Group {
      if let conversationID, let session {
        page(conversationID: conversationID, session: session)
      } else {
        // Rien à montrer : la scène n'existe que pour une conversation.
        Color.clear.onAppear { dismiss() }
      }
    }
    .frame(
      minWidth: Self.minimumSize.width,
      minHeight: Self.minimumSize.height
    )
  }

  private func page(conversationID: String, session: ConversationSession) -> some View {
    GeometryReader { geometry in
      let metrics = FocusPageMetrics.resolve(width: geometry.size.width, themes: themes)
      VStack(alignment: .leading, spacing: 0) {
        header(conversationID: conversationID, metrics: metrics, showsNetwork: geometry.size.width >= 520)
        FocusTranscriptView(session: session, metrics: metrics, includesEditor: false)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          // Le fil s'arrête à la ligne de l'entête : il ne remonte pas dessous.
          .clipped()
        FocusPageEditor(session: session, theme: theme)
          .padding(.bottom, metrics.isCompact ? Spacing.xs : Spacing.sm)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, metrics.leading)
      .padding(.trailing, metrics.trailing)
      .background(theme.paper.ignoresSafeArea())
      .overlay(alignment: .top) {
        ghostToolbar(conversationID: conversationID, metrics: metrics)
      }
      .overlay(alignment: .top) {
        HoverZone { hovering in
          withAnimation(chromeAnimation) { revealChrome(hovering) }
        }
        .frame(maxWidth: .infinity, maxHeight: Self.titleBarHeight)
        .accessibilityHidden(true)
      }
    }
    // Le contenu monte sous la barre : c'est là que l'entête prend place,
    // à la hauteur des feux.
    .ignoresSafeArea(edges: .top)
    .background {
      DetachedWindowConfigurator(
        conversationID: conversationID,
        isPinned: store.isPinnedDetached(conversationID),
        isDark: theme.id.prefersDarkChrome,
        minimumSize: Self.minimumSize
      )
      .frame(width: 0, height: 0)
    }
    // Le thème d'écriture vaut ici comme dans l'inbox : papier, encres, et
    // l'apparence claire ou sombre de la fenêtre elle-même.
    .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
    .tint(theme.accent)
    .onAppear {
      WindowOpener.shared.openWindow = openWindow
      store.restorePinnedDetached(conversationID)
      // La scène ne s'ouvre que sur geste : sans jeton, on referme.
      if !store.claimDetachRequest(conversationID) {
        dismiss()
      }
    }
    .onExitCommand { dismiss() }
  }

  // MARK: - Entête

  /// Nom + réseau, sur une ligne, cliquable. En fenêtre serrée le réseau
  /// s'efface : le nom vaut mieux qu'un libellé tronqué à deux lettres.
  private func header(conversationID: String, metrics: FocusPageMetrics, showsNetwork: Bool) -> some View {
    HStack(spacing: 6) {
      if let conversation {
        Button {
          isShowingInfo.toggle()
        } label: {
          HStack(spacing: 6) {
            ConversationAvatarView(conversation: conversation, size: metrics.isCompact ? 16 : 20, theme: theme)
            Text(conversation.title)
              .font(.system(size: metrics.isCompact ? 12 : 13, weight: .semibold))
              .foregroundStyle(theme.ink)
              .lineLimit(1)
              .truncationMode(.tail)
              .minimumScaleFactor(0.85)
            // Le réseau n'a sa place qu'en fenêtre large : tronqué à une
            // lettre, il n'apprend rien.
            if showsNetwork {
              Text(conversation.network.labelFR)
                .font(.system(size: 11))
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          conversation.isGroup
            ? "Infos du groupe \(conversation.title)"
            : "Fiche de \(conversation.title)"
        )
        .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
          ConversationInfoCard(conversation: conversation, theme: theme)
        }
      } else {
        Text("Conversation introuvable")
          .font(.system(size: 12))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Dans le creux de la barre, à droite des feux : le titre est du chrome,
    // pas du contenu — et la page gagne sa première ligne, précieuse en post-it.
    .padding(.leading, max(0, Self.trafficLightsClearance - metrics.leading))
    // À droite, la place des trois boutons fantômes ; en fenêtre serrée le
    // titre leur cède la ligne le temps du survol.
    .padding(.trailing, metrics.isCompact ? 0 : Self.ghostToolbarWidth)
    .frame(height: Self.titleBarHeight)
    .opacity(metrics.isCompact && isChromeRevealed ? 0 : 1)
  }

  /// La hauteur du creux de la barre, feux compris.
  static let titleBarHeight: CGFloat = 28
  /// Ce que les trois feux occupent depuis le bord gauche.
  static let trafficLightsClearance: CGFloat = 78
  /// Trois boutons fantômes et leurs entre-deux.
  static let ghostToolbarWidth: CGFloat = 96

  // MARK: - Barre d'outils fantôme

  /// Trois gestes, et rien d'autre : épingler, ramener dans l'inbox, archiver.
  /// En fenêtre serrée, les icônes se passent de leurs libellés.
  private func ghostToolbar(conversationID: String, metrics: FocusPageMetrics) -> some View {
    let isPinned = store.isPinnedDetached(conversationID)
    return HStack(spacing: 4) {
      Spacer(minLength: 0)
      SoftToolButton(
        systemImage: isPinned ? "pin.fill" : "pin",
        helpText: isPinned ? "Ne plus épingler (⌘⌥P)" : "Épingler au-dessus (⌘⌥P)",
        isEmphasized: isPinned
      ) {
        store.togglePinnedDetached(conversationID)
      }
      SoftToolButton(
        systemImage: "rectangle.split.2x1",
        helpText: "Ramener dans l’inbox (⌘⇧D)"
      ) {
        Task { await store.reattach(conversationID: conversationID) }
      }
      SoftToolButton(
        systemImage: store.isArchived(conversationID) ? "tray.and.arrow.up" : "archivebox",
        helpText: store.isArchived(conversationID) ? "Désarchiver (⌘E)" : "Archiver (⌘E)"
      ) {
        Task { await store.toggleArchived(conversationID: conversationID) }
      }
    }
    .padding(.horizontal, metrics.isCompact ? Spacing.xxs : Spacing.xs)
    .frame(height: Self.titleBarHeight)
    .opacity(isChromeRevealed ? 1 : 0)
    .allowsHitTesting(isChromeRevealed)
    .animation(chromeAnimation, value: isChromeRevealed)
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.2)
  }

  private func revealChrome(_ hovering: Bool) {
    hideChromeTask?.cancel()
    if hovering {
      isChromeRevealed = true
    } else {
      hideChromeTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled else { return }
        withAnimation(chromeAnimation) { isChromeRevealed = false }
      }
    }
  }
}

/// Le peu d'AppKit qu'une fenêtre détachée réclame : le titre masqué, le
/// contenu qui monte sous la barre, l'apparence du thème, le cadre retrouvé,
/// et — Lot F2 — le niveau flottant.
private struct DetachedWindowConfigurator: NSViewRepresentable {
  let conversationID: String
  let isPinned: Bool
  let isDark: Bool
  let minimumSize: CGSize

  @Environment(InboxStore.self) private var store

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.store = store
    context.coordinator.conversationID = conversationID
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.store = store
    coordinator.conversationID = conversationID
    let pinned = isPinned
    let dark = isDark
    let minSize = minimumSize
    DispatchQueue.main.async {
      guard let window = nsView.window else { return }
      coordinator.adopt(window)
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.minSize = NSSize(width: minSize.width, height: minSize.height)
      Self.applyLevel(pinned, to: window)
    }
  }

  /// Lot F2 — toujours au-dessus. `Scene.windowLevel(.floating)` (macOS 15+)
  /// vaudrait pour TOUTES les fenêtres du groupe : ici l'épingle est le geste
  /// d'UNE fenêtre. On pose donc le niveau sur la fenêtre elle-même, ce que
  /// `WindowChromeApplicator` fait déjà pour le reste du chrome — et qui a
  /// l'avantage de valoir aussi sur macOS 14.
  private static func applyLevel(_ pinned: Bool, to window: NSWindow) {
    window.level = pinned ? .floating : .normal
    // Épinglée, la fenêtre suit les bureaux — mais ne vole jamais le clavier :
    // elle ne devient active que si l'on clique dedans.
    window.collectionBehavior = pinned
      ? [.canJoinAllSpaces, .fullScreenAuxiliary]
      : [.fullScreenAuxiliary]
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Le peu d'état AppKit de la fenêtre. Non isolé : `NotificationCenter` rend
  /// la main sur la file principale, et tout ce qui touche au magasin le fait
  /// sous `MainActor.assumeIsolated`.
  final class Coordinator: NSObject, @unchecked Sendable {
    @MainActor var store: InboxStore?
    @MainActor var conversationID: String = ""
    @MainActor private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    func adopt(_ window: NSWindow) {
      guard self.window !== window else { return }
      stopObserving()
      self.window = window
      // La restauration système ne doit pas ressusciter cette fenêtre : c'est
      // le geste qui l'ouvre, et le cadre mémorisé qui la replace.
      window.isRestorable = false
      restoreFrame(window)
      store?.registerDetachedWindow(window, for: conversationID)
      observe(window)
      if window.isKeyWindow { store?.detachedWindowBecameKey(conversationID) }
    }

    @MainActor
    private func restoreFrame(_ window: NSWindow) {
      guard let frame = DetachedWindowState.frame(for: conversationID) else { return }
      // Un écran débranché depuis : on ne pose pas la fenêtre dans le vide.
      guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
      window.setFrame(frame, display: false)
    }

    @MainActor
    private func observe(_ window: NSWindow) {
      let center = NotificationCenter.default
      func watch(_ name: Notification.Name, _ action: @escaping @MainActor (Coordinator) -> Void) {
        tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            action(self)
          }
        })
      }
      watch(NSWindow.didBecomeKeyNotification) { $0.store?.detachedWindowBecameKey($0.conversationID) }
      watch(NSWindow.didResignKeyNotification) { $0.store?.detachedWindowResignedKey($0.conversationID) }
      watch(NSWindow.didMoveNotification) { $0.saveFrame() }
      watch(NSWindow.didResizeNotification) { $0.saveFrame() }
      watch(NSWindow.willCloseNotification) { coordinator in
        coordinator.saveFrame()
        coordinator.store?.unregisterDetachedWindow(for: coordinator.conversationID)
        coordinator.stopObserving()
      }
    }

    @MainActor
    private func saveFrame() {
      guard let window else { return }
      DetachedWindowState.saveFrame(window.frame, for: conversationID)
    }

    private func stopObserving() {
      let center = NotificationCenter.default
      tokens.forEach { center.removeObserver($0) }
      tokens.removeAll()
    }

    deinit {
      stopObserving()
    }
  }
}
