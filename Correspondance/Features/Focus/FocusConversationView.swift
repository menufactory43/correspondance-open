import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Les marges de la page, mesurées sur la largeur qu'on lui donne.
///
/// La grande marge de gauche d'iA Writer est un luxe de grande fenêtre : dans
/// une fenêtre détachée réduite à un post-it, elle mangerait la page entière.
/// La page respire quand elle est large, et se serre quand elle est étroite —
/// jamais l'inverse, jamais de largeur fixe qui déborde.
struct FocusPageMetrics: Equatable {
  var leading: CGFloat
  var trailing: CGFloat
  var top: CGFloat
  var bottom: CGFloat
  /// Fenêtre serrée : l'entête tient sur une ligne, les bannières s'effacent.
  var isCompact: Bool
  /// Une photo ne fait jamais déborder la colonne : au plus 360 points, et
  /// jamais plus que la page n'en laisse entre ses marges.
  var attachmentMaxWidth: CGFloat = 360

  /// La largeur de colonne du texte, en points — la longueur de ligne des
  /// réglages (64, 72 ou 80 caractères) traduite pour la police et le corps
  /// courants. Ce n'est qu'un plafond : sous cette largeur, la page prend ce
  /// qu'on lui laisse.
  var letterWidth: CGFloat = LayoutMetrics.letterWidth

  static let page = FocusPageMetrics(
    leading: LayoutMetrics.pageLeading,
    trailing: Spacing.xl,
    top: LayoutMetrics.pageTopInset * 0.4,
    bottom: LayoutMetrics.pageBottomInset,
    isCompact: false
  )

  @MainActor
  static func resolve(width: CGFloat, themes: ThemePreferences? = nil) -> FocusPageMetrics {
    let w = max(width, 0)
    let letterWidth = themes.map { $0.letterWidth(bodySize: $0.theme.bodySize * $0.textScale) }
      ?? LayoutMetrics.letterWidth
    let leading: CGFloat
    switch w {
    case ..<380: leading = 14
    case ..<640: leading = 14 + (w - 380) * (40 - 14) / (640 - 380)
    case ..<900: leading = 40 + (w - 640) * (LayoutMetrics.pageLeading - 40) / (900 - 640)
    default: leading = LayoutMetrics.pageLeading
    }
    let trailing: CGFloat = w < 380 ? 12 : (w < 640 ? 16 : Spacing.xl)
    return FocusPageMetrics(
      leading: leading,
      trailing: trailing,
      top: w < 380 ? 4 : (w < 640 ? 10 : LayoutMetrics.pageTopInset * 0.4),
      bottom: w < 380 ? Spacing.sm : (w < 640 ? Spacing.lg : LayoutMetrics.pageBottomInset),
      isCompact: w < 420,
      attachmentMaxWidth: max(80, min(360, w - leading - trailing)),
      letterWidth: letterWidth
    )
  }
}

/// Une conversation à la fois — page zen, chrome fantôme.
struct FocusConversationView: View {
  /// La session lue par cette page. `nil` = celle de l'inbox.
  var session: ConversationSession?

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Tourner la page : le nom paraît dans la même frame que la bascule, les
  /// paragraphes se posent un instant après. Les deux glissent d'un
  /// demi-interligne dans le sens du geste — vers le haut pour « suivante »,
  /// vers le bas pour « précédente » — assez pour donner un sens, pas assez
  /// pour être une animation. `turnPhase` va de 0 (page qui arrive) à 1.
  @State private var turnPhase: CGFloat = 1
  @State private var turnOffset: CGFloat = 0
  /// Le rang du fil précédent dans la file : c'est lui qui donne le sens.
  @State private var lastFocusIndex: Int?

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }
  private var live: ConversationSession? { session ?? store.primarySession }
  private var conversation: Conversation? {
    live.flatMap { store.conversationRow($0.conversationID) }
  }
  /// La page de l'inbox — celle qui a une file à parcourir. Une fenêtre
  /// détachée lit UN fil et ne tourne jamais de page.
  private var isPrimary: Bool { session == nil }

  /// « 3 sur 12 » : où l'on en est dans la file, sans barre. Rien si le fil
  /// ouvert n'est pas dans la file (archivé, filtré par le rail).
  private var queueLabel: String? {
    guard isPrimary, let index = store.focusIndex else { return nil }
    return "\(index + 1) sur \(store.activeQueue.count)"
  }

  var body: some View {
    GeometryReader { geometry in
      page(FocusPageMetrics.resolve(width: geometry.size.width, themes: themes))
    }
  }

  private func page(_ metrics: FocusPageMetrics) -> some View {
    ZStack(alignment: .topLeading) {
      theme.paper.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: metrics.top)

        if store.usingDemoData, !metrics.isCompact {
          PermissionBanner()
            .padding(.bottom, Spacing.lg)
            .opacity(isWriting ? 0 : 1)
        }

        if let conversation {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(conversation.title)
              .font(Typography.toolbarPhrase(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              .lineLimit(1)
              .truncationMode(.tail)
            if let queueLabel, !metrics.isCompact {
              Text(queueLabel)
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkTertiary.opacity(0.8))
                .monospacedDigit()
                .accessibilityLabel("Conversation \(queueLabel)")
            }
          }
          .padding(.bottom, metrics.isCompact ? Spacing.xs : Spacing.md)
          .opacity(isWriting ? 0 : turnPhase)
          .offset(y: (1 - turnPhase) * turnOffset)
          .accessibilityHidden(isWriting)

          FocusTranscriptView(session: live, metrics: metrics, turnOffset: turnOffset * 1.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(store.isLoading ? "Chargement…" : "Rien à lire pour l’instant.")
              .font(Typography.emptyState(themes.typeface))
              .foregroundStyle(theme.inkSecondary)
            Text(store.matrixStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
            Text(store.iMessageStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: metrics.letterWidth, alignment: .leading)
      .padding(.leading, metrics.leading)
      .padding(.trailing, metrics.trailing)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .animation(chromeAnimation, value: isWriting)

      // Les lisières : survoler le bord gauche ou droit de la page montre une
      // flèche pâle à hauteur de lecture. Les chevrons de la barre fantôme
      // restent ; ceux-ci sont là où l'œil est. Pas dans une fenêtre serrée,
      // où la marge ne les loge pas, ni dans une fenêtre détachée, qui n'a
      // pas de file.
      if isPrimary, !metrics.isCompact {
        FocusEdgeTurn(direction: .previous, isEnabled: canTurn(-1)) { turn(-1) }
          .frame(maxHeight: .infinity)
          .frame(maxWidth: .infinity, alignment: .leading)
          .opacity(isWriting ? 0.34 : 1)
        FocusEdgeTurn(direction: .next, isEnabled: canTurn(1)) { turn(1) }
          .frame(maxHeight: .infinity)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .opacity(isWriting ? 0.34 : 1)
      }
    }
    .onChange(of: live?.conversationID) { _, _ in
      guard isPrimary else { return }
      noteTurn(to: store.focusIndex)
    }
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
  }

  private func canTurn(_ step: Int) -> Bool {
    guard let index = store.focusIndex else { return false }
    let target = index + step
    return target >= 0 && target < store.activeQueue.count
  }

  private func turn(_ step: Int) {
    Task { @MainActor in
      if step > 0 { await store.focusNext() } else { await store.focusPrevious() }
    }
  }

  /// La page tourne : sens du geste depuis le rang dans la file, phase remise
  /// à zéro sans animer, puis ramenée à un — au tour de boucle suivant, pour
  /// que les deux écritures ne se fondent pas en une seule.
  private func noteTurn(to index: Int?) {
    defer { lastFocusIndex = index }
    let direction: CGFloat
    switch (lastFocusIndex, index) {
    case let (old?, new?) where new > old: direction = 1
    case let (old?, new?) where new < old: direction = -1
    default: direction = 0
    }
    guard !reduceMotion else { return }
    turnOffset = 6 * direction
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { turnPhase = 0 }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.32)) { turnPhase = 1 }
    }
  }

}

/// Une lisière de la page : une bande de survol qui n'attrape rien (la
/// sélection de texte reste libre), et une flèche qui n'existe qu'au survol —
/// elle seule prend le clic.
struct FocusEdgeTurn: View {
  enum Direction {
    case previous, next

    var systemImage: String { self == .next ? "chevron.right" : "chevron.left" }
    var label: String { self == .next ? "Conversation suivante" : "Conversation précédente" }
    var hint: String { self == .next ? "suivante ⌘↓" : "⌘↑ précédente" }
  }

  var direction: Direction
  var isEnabled: Bool
  var action: () -> Void

  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  private var theme: WritingTheme { themes.theme }
  private var isShown: Bool { isHovered && isEnabled }

  var body: some View {
    ZStack(alignment: .bottom) {
      HoverZone { hovering in
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isHovered = hovering }
      }
      .accessibilityHidden(true)

      Button(action: action) {
        Image(systemName: direction.systemImage)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
          .frame(width: 32, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(direction.label)
      .accessibilityLabel(direction.label)
      .frame(maxHeight: .infinity)
      .opacity(isShown ? 1 : 0)
      .offset(x: isShown ? 0 : (direction == .next ? -6 : 6))
      .allowsHitTesting(isShown)

      Text(direction.hint)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary.opacity(0.8))
        .padding(.bottom, Spacing.lg)
        .opacity(isShown ? 1 : 0)
        .accessibilityHidden(true)
    }
    .frame(width: LayoutMetrics.focusEdgeTurnWidth)
  }
}

/// Fil en prose — le brouillon est le dernier paragraphe de la page.
struct FocusTranscriptView: View {
  /// La session lue. `nil` = celle de l'inbox.
  var session: ConversationSession?
  var metrics: FocusPageMetrics = .page
  /// Faux quand la page pose elle-même le composer sous le fil — c'est le cas
  /// de la fenêtre détachée, où le composer ne doit jamais défiler hors de vue.
  var includesEditor = true
  /// D'où la page arrive quand elle tourne (cf. `FocusConversationView`) :
  /// le fil glisse de cette hauteur en se posant. Zéro = il paraît sur place.
  var turnOffset: CGFloat = 0

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShowingThread = false
  /// La page paraît par sa QUEUE, comme le fil de l'Inbox : les vingt derniers
  /// paragraphes d'abord, le reste monté au-dessus par paliers d'une frame,
  /// hors champ — le bas tient, rien ne bouge à l'écran. Avant, les cent vingt
  /// paragraphes se construisaient d'un bloc, page blanche pendant ce temps :
  /// c'est ce qui faisait paraître la bascule lente. `nil` = entier.
  /// Et comme dans l'Inbox, le reste ne monte plus d'office : de quoi remplir
  /// deux écrans, puis un cran chaque fois que le lecteur touche le haut
  /// (`mountOlderIfNeeded`).
  @State private var launchTail: Int? = ThreadMetrics.launchTailCount
  /// Le compte de messages pour lequel une expansion est programmée : si le
  /// fil a changé entre-temps, la passe suivante reprogrammera la sienne.
  @State private var pendingExpansionCount: Int?
  /// Le jalon « fil complet » ne s'écrit qu'une fois par page.
  @State private var didReportFull = false
  /// La géométrie du dernier défilement, hors du graphe : elle bouge à chaque
  /// frame et personne ne la lit dans un corps.
  @State private var scrollGeometry = FocusScrollGeometry()
  /// L'encre dit ce qui est nouveau : ce qu'on avait déjà lu en ouvrant la
  /// page reste en encre secondaire, ce qui est arrivé depuis — et ce qu'on
  /// écrit — est en encre pleine. L'œil sait où reprendre, sans pastille.
  /// Vide quand rien n'était nouveau : une page sans nouvelle se lit entière,
  /// pas grise. Figé à l'ouverture, jusqu'à la page suivante.
  @State private var readIDs: Set<String> = []
  @State private var hasSettledInk = false
  /// Faux tant que la page se met en place : à l'ouverture d'une conversation,
  /// les vingt derniers paragraphes ne doivent pas se tracer un par un.
  @State private var animatesArrivals = false
  /// Ce que la page considère comme déjà posé. Tout ce qui arrive après se
  /// trace ; ce qui est là depuis toujours paraît sans cérémonie.
  @State private var settledMessageID: String?
  /// Ce qui a déjà joué le geste, par empreinte : la bulle optimiste et la
  /// copie du Relais qui la remplace ne jouent qu'une fois.
  private let inkLedger = MessageArrivalLedger()
  /// Suppression demandée au clic droit, en attente de confirmation.
  @State private var pendingDeletion: PendingDeletion?
  /// Au lancement, la page reste blanche jusqu'à ce que la fenêtre soit peinte :
  /// construire cent paragraphes avant la première frame, c'est le rebond de
  /// trop dans le Dock. Le fil est de toute façon invisible tant qu'il n'est
  /// pas ancré en bas — il arrive donc entier, un instant plus tard, sans saut.
  @State private var awaitsFirstFrame = !LaunchGate.didPaintFirstWindow
  /// Vrai tant que le lecteur n'a pas remonté la page : c'est ce qui décide si
  /// une hauteur qui change (réaction, citation, aperçu) le garde en bas.
  @State private var isNearBottom = true

  /// Le message visé et l'étendue de sa suppression — le temps de l'alerte.
  private struct PendingDeletion: Identifiable {
    let messageID: String
    let scope: MessageBubbleView.Deletion

    var id: String { "\(messageID)|\(scope.rawValue)" }
  }

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }
  private var live: ConversationSession? { session ?? store.primarySession }
  private var conversationID: String? { live?.conversationID }
  /// Tout ce que la session connaît — ce que le fil MONTE est `thread`.
  private var fullThread: [ChatMessage] { awaitsFirstFrame ? [] : (live?.messages ?? []) }
  private var thread: [ChatMessage] {
    guard let tail = launchTail else { return fullThread }
    return Array(fullThread.suffix(tail))
  }
  private var row: Conversation? { conversationID.flatMap { store.conversationRow($0) } }
  /// L'ancre du vrai bas de la page — sous la marge basse, pas sous le
  /// brouillon : `scrollTo(id, anchor: .bottom)` sur le brouillon s'arrêtait
  /// une marge trop haut.
  private static let bottomAnchorID = "focus-bottom"

  /// Le geste choisi dans les réglages — encre ou plume.
  private var arrival: MessageArrival { themes.messageArrival }

  /// Le geste ne joue que sur un vrai message, jamais sur une bascule de
  /// conversation. Et il ne dure que son temps : passé ce délai le paragraphe
  /// est un paragraphe comme les autres, et il ne se retracera pas si le
  /// défilement le fait renaître.
  /// Vrai pour le dernier message tant qu'il n'a pas fini de se poser. Calculé
  /// dans le corps de la vue : la ligne connaît donc son sort dès sa naissance,
  /// et sa valeur initiale suffit à lancer le geste — pas de rattrapage.
  private func isFresh(_ message: ChatMessage) -> Bool {
    guard animatesArrivals,
          store.didSettleInitialMatrixSync,
          message.id == thread.last?.id,
          message.id != settledMessageID,
          // Un message d'hier découvert en ouvrant la page est déjà vu : posé, pas tracé.
          MessageArrivalPolicy.isNewArrival(sentAt: message.sentAt),
          // Mon envoi a joué en bulle optimiste : sa copie du Relais, sous un
          // autre identifiant, paraît posée au lieu de rejouer le geste.
          !inkLedger.hasInked(message)
    else { return false }
    inkLedger.remember(message)
    return true
  }

  private func noteArrival(increased: Bool) {
    guard increased, animatesArrivals else { return }
    let id = thread.last?.id
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      if thread.last?.id == id { settledMessageID = id }
    }
  }

  /// La grande marge basse fait respirer l'éditeur QUAND il vit dans le fil —
  /// la page se termine par sa réponse, comme une lettre. Posé dessous
  /// (fenêtre détachée, réponse rapide), elle ne laisserait qu'un grand vide
  /// entre le dernier message et lui. (Une « ligne de lecture » à 60 % de la
  /// hauteur, façon machine à écrire, a été essayée et retirée : la page
  /// finie se lit avec sa réponse en bas.)
  private var bottomInset: CGFloat { includesEditor ? metrics.bottom : Spacing.sm }

  var body: some View {
    let inset = bottomInset
    return ScrollViewReader { proxy in
      ScrollView {
        // Pile simple, et surtout pas paresseuse. Un `LazyVStack` ancré en bas
        // sur des lignes hautes et inégales — des photos — ne converge jamais :
        // il place, découvre que les hauteurs ne sont pas celles qu'il croyait,
        // retraduit l'ancre, replace, sans fin. Le fil tournait à 80 % d'un cœur
        // sans que rien ne bouge à l'écran. Le fil est borné à cent vingt
        // messages : les construire tous coûte moins cher que cette boucle.
        VStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(messageGroups) { group in
            VStack(alignment: .leading, spacing: 6) {
              // Fil fusionné : la page dit d'où repart la suite, une fois par
              // bascule de réseau — jamais plus.
              if let origin = group.networkOrigin {
                Label(origin.labelFR, systemImage: origin.systemImage)
                  .font(Typography.toolbarPhrase(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              // Une page ne réannonce pas son locuteur à chaque phrase : un
              // libellé par prise de parole, et rien du tout en tête-à-tête.
              if let label = focusLabel(for: group) {
                Text(label)
                  .font(Typography.toolbarPhrase(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              ForEach(group.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(message.attachments) { raw in
                    let attachment = FocusAttachment.repaired(raw)
                    if let url = attachment.resolvedFileURL, attachment.isImage {
                      AttachmentImageView(
                        url: url,
                        maxWidth: metrics.attachmentMaxWidth,
                        maxHeight: 400,
                        cornerRadius: 8,
                        placeholder: theme.paperSecondary,
                        border: nil,
                        label: attachment.filename ?? "Image"
                      ) {
                        EmptyView()
                      }
                    } else if let url = attachment.resolvedFileURL, attachment.isVideo {
                      AttachmentVideoView(
                        url: url,
                        maxWidth: metrics.attachmentMaxWidth,
                        maxHeight: 400,
                        cornerRadius: 8,
                        placeholder: theme.paperSecondary,
                        border: nil,
                        label: attachment.filename ?? "Vidéo"
                      )
                    }
                  }
                  if shouldShowFocusText(message) {
                    LinkedText(
                      text: message.text,
                      tint: theme.accent,
                      mentions: MentionHighlight.withAgents(live?.mentionCandidates.map(\.name) ?? [])
                    )
                      .font(pageFont)
                      .foregroundStyle(
                        (readIDs.contains(message.id) ? theme.inkSecondary : theme.ink)
                          .opacity(message.isFromMe ? 0.72 : 1)
                      )
                      .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: readIDs.isEmpty)
                      // L'interligne DE LETTRE du thème, entier : la page Focus
                      // est de la prose, et la prose se lit aérée. Il suit
                      // l'échelle comme le corps — les deux vont ensemble.
                      .lineSpacing(theme.lineSpacing(forBodySize: pageBodySize))
                  }
                }
                .opacity(message.isPending ? 0.5 : 1)
                .id(message.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .messageArrival(
                  arrival,
                  isFresh: isFresh(message),
                  isEnabled: !reduceMotion
                )
                // La page n'a pas de bulles à survoler : le clic droit est le
                // seul endroit où retirer un paragraphe sans quitter le Focus.
                .contentShape(Rectangle())
                .contextMenu { paragraphMenu(for: message) }
              }
            }
            .opacity(isWriting ? 0.34 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isWriting)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          ForEach(store.scheduledMessages(for: conversationID ?? "")) { scheduled in
            ScheduledMessageRow(message: scheduled, theme: theme, typeface: themes.typeface, isProse: true)
              .font(pageFont)
              .padding(.top, Spacing.sm)
              .opacity(isWriting ? 0.34 : 1)
          }

          if let config = store.sendLaterConfig, isPrimary {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
              .padding(.top, Spacing.sm)
          }

          if includesEditor, let live {
            FocusPageEditor(session: live, theme: theme)
              .id("draft")
              .popover(
                isPresented: Binding(
                  get: { store.sendLaterPicker != nil && isPrimary },
                  set: { if !$0 { store.sendLaterPicker = nil } }
                ),
                arrowEdge: .top
              ) {
                SendLaterPicker()
              }
          }
        }
        .padding(.bottom, inset)
        // L'ancre du vrai bas — c'est elle qu'on vise, jamais le brouillon.
        .overlay(alignment: .bottom) {
          Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
        }
      }
      .defaultScrollAnchor(.bottom)
      .scrollIndicators(.never)
      // Remonter le fil rappelle la barre d'outils, comme un geste de retour
      // en arrière ; descendre la laisse dormir.
      .overlay(alignment: .top) {
        // Même soin qu'en Inbox : le fil se dissout sous le titre de la page
        // au lieu d'y être tranché.
        TopScrollFade(theme: theme, height: Spacing.lg, reachesWindowEdge: false)
      }
      .onScrollUp {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
          store.flashFocusChrome()
        }
      }
      .opacity(isShowingThread ? 1 : 0)
      .offset(y: isShowingThread ? 0 : turnOffset)
      .overlay {
        MacOverlayScrollerHider()
          .allowsHitTesting(false)
      }
      // Une réaction, une citation, un aperçu qui arrive après coup : la page
      // grandit sans que son compte bouge, et le bas doit tenir quand même.
      .keepScrolledToBottom(
        isNearBottom: $isNearBottom,
        onGeometry: { noteScrollGeometry($0, proxy: proxy) }
      ) { keepBottom(proxy) }
      .onAppear { pinToBottom(proxy) }
      .task {
        guard awaitsFirstFrame else { return }
        // Langue et liens des paragraphes se calculent sur un autre cœur
        // pendant qu'AppKit monte la fenêtre : la page les trouve prêts.
        ThreadPrewarm.schedule(live?.messages ?? [])
        await LaunchGate.firstWindowOnScreen()
        awaitsFirstFrame = false
        pinToBottom(proxy)
      }
      .onChange(of: fullThread.count) { oldCount, newCount in
        // Le bas est l'ancre : on le recale sans animer, le geste se joue
        // dans le paragraphe. Animer ici ferait glisser le bas de la page.
        noteArrival(increased: newCount > oldCount)
        pinToBottom(proxy)
      }
      // Redimensionner une fenêtre détachée ne doit pas renvoyer le fil à son
      // début : le bas de la page est ce qu'on lit.
      .onChange(of: metrics) { _, _ in
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
      }
      .onChange(of: conversationID) { _, _ in
        LaunchTrace.event("select")
        isShowingThread = false
        launchTail = ThreadMetrics.launchTailCount
        didReportFull = false
        readIDs = []
        hasSettledInk = false
        animatesArrivals = false
        settledMessageID = thread.last?.id
        inkLedger.reset()
        isNearBottom = true
        pinToBottom(proxy)
      }
      .alert(
        pendingDeletion?.scope.titleFR ?? "",
        isPresented: Binding(
          get: { pendingDeletion != nil },
          set: { if !$0 { pendingDeletion = nil } }
        ),
        presenting: pendingDeletion
      ) { deletion in
        Button("Supprimer", role: .destructive) {
          switch deletion.scope {
          case .locally:
            store.deleteLocally(messageID: deletion.messageID)
          case .everywhere:
            Task { await store.deleteEverywhere(messageID: deletion.messageID) }
          }
        }
        Button("Annuler", role: .cancel) {}
      } message: { deletion in
        Text(deletion.scope.detailFR)
      }
    }
  }

  /// Clic droit sur un paragraphe : copier, et les deux suppressions — les mêmes
  /// qu'en Inbox, avec la même confirmation.
  @ViewBuilder
  private func paragraphMenu(for message: ChatMessage) -> some View {
    if !message.text.isEmpty {
      Button("Copier le texte") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
      Divider()
    }
    if store.canDeleteEverywhere(message) {
      Button("Supprimer pour tout le monde…", role: .destructive) {
        pendingDeletion = PendingDeletion(messageID: message.id, scope: .everywhere)
      }
    }
    Button("Supprimer ici…", role: .destructive) {
      pendingDeletion = PendingDeletion(messageID: message.id, scope: .locally)
    }
  }

  /// Si on lisait le bas, on y reste — dans la même passe, sans animer : rien
  /// ne doit défiler à l'écran. Remonter d'un cran libère l'ancre.
  private func keepBottom(_ proxy: ScrollViewProxy) {
    guard isNearBottom else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
  }

  private func pinToBottom(_ proxy: ScrollViewProxy) {
    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    ThreadPrewarm.schedule(fullThread)
    DispatchQueue.main.async {
      proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
      // Tant que le fil n'est pas arrivé, rien n'est « posé » ni à montrer.
      guard !awaitsFirstFrame else { return }
      // La page se pose : un fondu et le glissement du geste, jamais plus.
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { isShowingThread = true }
      // Les mêmes jalons que le fil de l'Inbox : `tools/launch` les relit.
      LaunchTrace.mark("thread")
      LaunchTrace.event("shown", fullThread.count)
      LaunchBench.noteShown(count: fullThread.count)
      LaunchGate.markThreadPainted()
      expandTail(proxy)
      settleInk()
      // Ce qui est à l'écran à l'ouverture est déjà posé.
      settledMessageID = thread.last?.id
      // Une page encore vide n'arme pas le geste : ce qui va la remplir est un
      // chargement, pas une arrivée. Cf. `ThreadView`.
      animatesArrivals = !thread.isEmpty
    }
  }

  /// Ce qui était déjà lu à l'ouverture — le compte de non-lus au moment de
  /// la sélection le dit. Une seule fois par page, sur la page de l'inbox
  /// (une fenêtre détachée n'a pas ce compte), et seulement s'il y a du neuf.
  private func settleInk() {
    guard isPrimary, !hasSettledInk, !fullThread.isEmpty else { return }
    hasSettledInk = true
    let fresh = store.unreadAtSelection
    guard fresh > 0, fresh < fullThread.count else { return }
    readIDs = Set(fullThread.prefix(fullThread.count - fresh).map(\.id))
  }

  /// La queue est peinte ; ce qui manque pour remplir l'écran monte au-dessus,
  /// hors champ, un palier à la fois — cf. `ThreadView`, même mécanique.
  private func expandTail(_ proxy: ScrollViewProxy) {
    guard launchTail != nil, !fullThread.isEmpty else { return }
    let count = fullThread.count
    pendingExpansionCount = count
    Task { @MainActor in
      // Un court délai, pour que la frame de la queue parte avant ; puis les
      // mémos de langue et de liens, s'ils sont encore en route — un temps
      // borné, jamais au prix de la page.
      try? await Task.sleep(for: .milliseconds(80))
      await ThreadPrewarm.ready(within: .milliseconds(250))
      guard pendingExpansionCount == count, fullThread.count == count else { return }
      pendingExpansionCount = nil
      mountOlderIfNeeded(idle: false, proxy: proxy)
    }
  }

  private func noteScrollGeometry(_ probe: ThreadScrollProbe, proxy: ScrollViewProxy) {
    scrollGeometry.content = probe.content
    scrollGeometry.viewport = probe.viewport
    scrollGeometry.top = probe.top
    mountOlderIfNeeded(idle: probe.idle, proxy: proxy)
  }

  /// Monte-t-on la suite de la page ? Quand ce qui est monté ne remplit pas
  /// deux écrans (le bas tient, rien ne bouge), ou quand le lecteur s'est
  /// arrêté tout en haut (la suite se pose au-dessus, le premier paragraphe
  /// reste sous ses yeux). Sinon rien — et le jalon « fil complet » s'écrit.
  private func mountOlderIfNeeded(idle: Bool, proxy: ScrollViewProxy) {
    guard isShowingThread, pendingExpansionCount == nil, scrollGeometry.viewport > 0 else { return }
    if launchTail != nil, thread.count < fullThread.count {
      if scrollGeometry.content < scrollGeometry.viewport * 2 {
        mountOlder(anchored: false, proxy: proxy)
        return
      }
      if idle, scrollGeometry.top <= 4 {
        mountOlder(anchored: true, proxy: proxy)
        return
      }
    }
    guard !didReportFull else { return }
    didReportFull = true
    LaunchTrace.mark("thread-full")
    LaunchTrace.event("full", fullThread.count)
  }

  private func mountOlder(anchored: Bool, proxy: ScrollViewProxy) {
    guard let tail = launchTail else { return }
    let anchorID = thread.first?.id
    let next = tail + ThreadMetrics.expansionStep
    launchTail = next < fullThread.count ? next : nil
    guard anchored, let anchorID else { return }
    isNearBottom = false
    DispatchQueue.main.async {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { proxy.scrollTo(anchorID, anchor: .top) }
    }
  }

  /// Le corps effectif de la page — échelle comprise. L'interligne s'y accroche.
  private var pageBodySize: CGFloat { theme.bodySize * themes.textScale }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: pageBodySize)
  }

  private var isGroup: Bool { row?.isGroup == true }

  /// Vrai quand cette page est celle de l'inbox : les états partagés (envoyer
  /// plus tard, recherche dans le fil) ne valent que pour elle.
  private var isPrimary: Bool { live != nil && live === store.primarySession }

  private var messageGroups: [MessageGroup] {
    MessageGrouping.groups(
      for: thread,
      showsSenderNames: isGroup,
      showsNetworkOrigin: isMergedThread
    )
  }

  private var isMergedThread: Bool {
    guard let id = conversationID else { return false }
    return store.isMerged(id)
  }

  /// En groupe, chaque prise de parole s'annonce une fois ; en tête-à-tête, la
  /// page se lit comme une lettre — l'encre plus pâle dit déjà que c'est moi.
  private func focusLabel(for group: MessageGroup) -> String? {
    guard isGroup else { return nil }
    return group.isFromMe ? "Toi" : group.senderLabel
  }
}

/// Au repos / à la pause : photo + envoyer. Pendant la frappe : une feuille.
struct FocusPageEditor: View {
  /// Le brouillon écrit ici est celui de CETTE session — l'inbox et une fenêtre
  /// détachée n'écrivent jamais dans la même page.
  var session: ConversationSession
  var theme: WritingTheme
  /// Appelé quand le message est bel et bien parti — la réponse rapide s'en
  /// sert pour se refermer derrière lui.
  var onSent: (() -> Void)?
  /// Posé sous le fil (fenêtre détachée, réponse rapide) : au-delà de cette
  /// hauteur le champ défile en lui-même, et le fil garde la sienne.
  var maxEditorHeight: CGFloat?

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isFocused = false
  @State private var mentionRouter = MentionKeyRouter()
  @State private var isActivelyTyping = false
  @State private var idleTask: Task<Void, Never>?
  @State private var isTrayExpanded = false

  private var text: Binding<String> { Bindable(session).draftText }
  private var isSending: Bool { session.isSending }
  /// « Plus tard » n'est posé que sur le composer de l'inbox.
  private var isScheduling: Bool { store.sendLaterConfig != nil && isPrimary }

  private var canSend: Bool { session.canSend }

  private var isPrimary: Bool { session === store.primarySession }

  private func onAttach() { store.pickAttachments(into: session) }
  /// « Plus tard » appartient à l'inbox : hors d'elle, le tiroir ne le propose pas.
  private var onSendLater: (() -> Void)? {
    isPrimary ? { store.toggleSendLaterPicker() } : nil
  }
  private func onSend() {
    Task {
      await store.send(session: session)
      // Un envoi refusé remet le brouillon en place : on ne prévient que du départ.
      if !session.canSend { onSent?() }
    }
  }

  private var showsChrome: Bool { !isActivelyTyping }

  /// Les touches que le champ tend à la page. Le menu « @ » a la main
  /// d'abord ; puis Entrée envoie et Échap quitte.
  private func handleCommand(_ command: GrowingTextEditor.Command) -> Bool {
    switch command {
    case .moveUp: return mentionRouter.send(.up)
    case .moveDown: return mentionRouter.send(.down)
    case .tab: return mentionRouter.send(.pick)
    case .send:
      if mentionRouter.send(.pick) { return true }
      // Rien à envoyer : Entrée ne fait rien, et surtout pas une ligne vide.
      guard canSend, !isSending else { return true }
      endTyping()
      onSend()
      return true
    case .escape:
      if mentionRouter.send(.escape) { return true }
      isFocused = false
      endTyping()
      return true
    }
  }

  private var pageBodySize: CGFloat { theme.bodySize * themes.textScale }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: pageBodySize)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !session.pendingAttachmentPaths.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(session.pendingAttachmentPaths.enumerated()), id: \.offset) { index, path in
              ZStack(alignment: .topTrailing) {
                if let img = NSImage(contentsOfFile: path) {
                  Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button {
                  session.pendingAttachmentPaths.remove(at: index)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
              }
            }
          }
        }
      }

      HStack(alignment: .top, spacing: 8) {
        // Une vue AppKit, pas un `TextField` vertical : celui-ci ne suit pas
        // la largeur d'une fenêtre détachée qu'on redimensionne, et oublie
        // l'interligne dans sa hauteur (voir `GrowingTextEditor`).
        GrowingTextEditor(
          text: text,
          isFocused: $isFocused,
          placeholder: showsChrome ? "Répondre…" : "",
          font: themes.typeface.nsFont(size: pageBodySize),
          textColor: NSColor(theme.ink),
          placeholderColor: NSColor(theme.inkTertiary),
          caretColor: NSColor(theme.caret),
          // Même interligne que la prose qu'on relit juste au-dessus.
          lineSpacing: theme.lineSpacing(forBodySize: pageBodySize),
          maxHeight: maxEditorHeight,
          onCommand: handleCommand
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .mentionMenu(
          text: text, session: session, theme: theme, font: pageFont,
          lineSpacing: theme.lineSpacing(forBodySize: pageBodySize),
          router: mentionRouter
        )

        ComposerPlusTray(
          theme: theme,
          isScheduling: isScheduling,
          iconSize: 18,
          isExpanded: $isTrayExpanded,
          onAttach: onAttach,
          onSendLater: onSendLater
        )
        .opacity(showsChrome ? 1 : 0)
        .allowsHitTesting(showsChrome)

        sendButton
          .opacity(showsChrome ? 1 : 0)
          .allowsHitTesting(showsChrome)
      }
    }
    .padding(.top, 8)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.edge.opacity(0.55))
        .frame(height: 1)
        .opacity(showsChrome ? 1 : 0)
    }
    .onChange(of: session.draftText) { _, newValue in
      if isTrayExpanded { isTrayExpanded = false }
      guard isFocused, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      noteTyping()
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { endTyping() }
    }
    .onDisappear {
      idleTask?.cancel()
      store.isComposerFocused = false
    }
  }

  private var sendButton: some View {
    Button {
      endTyping()
      onSend()
    } label: {
      Image(systemName: isScheduling ? "clock.badge.checkmark" : "arrow.up")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(canSend ? theme.paper : theme.inkTertiary.opacity(0.45))
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(canSend ? theme.accent : theme.inkTertiary.opacity(0.12))
        )
    }
    .buttonStyle(.plain)
    .disabled(!canSend || isSending)
    .help(isScheduling ? "Programmer l’envoi" : "Envoyer")
    .accessibilityLabel(isScheduling ? "Programmer l’envoi" : "Envoyer")
  }

  private func noteTyping() {
    isActivelyTyping = true
    store.isComposerFocused = true
    idleTask?.cancel()
    idleTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      guard !Task.isCancelled else { return }
      isActivelyTyping = false
      store.isComposerFocused = false
    }
  }

  private func endTyping() {
    idleTask?.cancel()
    isActivelyTyping = false
    store.isComposerFocused = false
  }
}

private enum FocusAttachment {
  /// Ré-attache le fichier si le chemin en cache est périmé. L'identifiant d'une
  /// pièce jointe bridgée est son MXC : le média déjà téléchargé se retrouve sous
  /// ce nom, sans redemander quoi que ce soit au serveur.
  static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = MatrixAttachmentStore.existingLocalPath(
      forMXC: attachment.id,
      contentType: attachment.contentType
    ) {
      copy.localPath = path
    }
    return copy
  }
}

private func shouldShowFocusText(_ message: ChatMessage) -> Bool {
  let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return false }
  let hasVisibleImage = message.attachments.contains {
    let repaired = FocusAttachment.repaired($0)
    return repaired.isImage && repaired.resolvedFileURL != nil
  }
  if hasVisibleImage, trimmed == "📷 Photo" { return false }
  return true
}

/// SwiftUI pose souvent l’overlay *à côté* du NSScrollView, pas dedans.
/// On cherche frères + ancêtres, et on re-masque pendant le geste.
private struct MacOverlayScrollerHider: NSViewRepresentable {
  func makeNSView(context: Context) -> OverlayScrollerHiderView {
    OverlayScrollerHiderView()
  }

  func updateNSView(_ nsView: OverlayScrollerHiderView, context: Context) {
    nsView.hideNearbyScrollers()
  }
}

private final class OverlayScrollerHiderView: NSView {
  private var tokens: [NSObjectProtocol] = []

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    hideNearbyScrollers()
    startObserving()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    hideNearbyScrollers()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stopObserving() }
  }

  func hideNearbyScrollers() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var current: NSView? = self
      while let view = current {
        Self.mute(in: view)
        current = view.superview
      }
    }
  }

  private static func mute(in view: NSView) {
    if let scroll = view as? NSScrollView {
      mute(scroll)
    }
    if view is NSScroller {
      view.alphaValue = 0
      view.isHidden = true
    }
    for sub in view.subviews {
      if let scroll = sub as? NSScrollView {
        mute(scroll)
      }
      if sub is NSScroller {
        sub.alphaValue = 0
        sub.isHidden = true
      }
    }
  }

  private static func mute(_ scroll: NSScrollView) {
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
      scroller.wantsLayer = true
      scroller.alphaValue = 0
      scroller.isHidden = true
      scroller.layer?.opacity = 0
      scroller.isEnabled = false
    }
  }

  private func startObserving() {
    stopObserving()
    let nc = NotificationCenter.default
    tokens.append(nc.addObserver(
      forName: NSScrollView.didLiveScrollNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
    tokens.append(nc.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard note.object is NSClipView else { return }
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
  }

  private func stopObserving() {
    let nc = NotificationCenter.default
    tokens.forEach { nc.removeObserver($0) }
    tokens.removeAll()
  }
}

/// Cf. `FocusConversationView.scrollGeometry` — une boîte, pas un état observé.
@MainActor
final class FocusScrollGeometry {
  var content: CGFloat = 0
  var viewport: CGFloat = 0
  var top: CGFloat = 0
}
