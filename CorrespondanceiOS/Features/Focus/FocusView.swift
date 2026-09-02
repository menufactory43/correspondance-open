import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Focus : la ligne.
///
/// Sur Mac, Focus enlève la barre latérale. Sur iPhone il n'y a rien de tel à
/// enlever : ce qu'il enlève, c'est l'aller-retour vers la liste, l'historique
/// qui n'attend rien, et l'hésitation sur ce qu'on fait d'une conversation.
///
/// Tout ce qui attend est aligné sur une ligne verticale paginée, une
/// conversation par écran, la suivante qui dépasse. Le geste vertical ne fait
/// que se déplacer — il ne décide rien. Chaque décision est un bouton :
/// Archiver, Rappel, Passer. Répondre est la sortie naturelle : la page
/// s'en va, une bande « Répondu » reste quelques secondes avec « Annuler ».
/// Partir avant la fin n'est pas un échec : le reste attend.
///
/// Deux vitesses sur le seuil : Répondre (la ligne avec composer) et Trier (la
/// même ligne sans composer — Archiver / Rappel / Garder — pour faire le tri
/// dans une file d'attente et répondre plus tard, au Mac).
struct FocusView: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// La vitesse choisie sur le seuil.
  @State private var pass: FocusPass = .reply
  /// La ligne en cours : les fils dans l'ordre où on les voit. `nil` = seuil.
  @State private var line: [String]?
  /// La page sous les yeux.
  @State private var currentID: String?
  /// La bande « Répondu · Annuler » posée en haut de la ligne.
  @State private var banner: Banner?
  @State private var bannerTask: Task<Void, Never>?
  /// Le bilan de la session, pour « À jour ».
  @State private var tally = Tally()

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  enum FocusPass: String, CaseIterable, Identifiable {
    case reply
    case sort
    var id: String { rawValue }
    var labelFR: String {
      switch self {
      case .reply: "Répondre"
      case .sort: "Trier"
      }
    }
  }

  /// Ce qu'on a décidé d'une page, et comment le défaire.
  private enum Decision {
    case replied(localID: String)
    case archived
    case reminded(Date)
    case kept

    var labelFR: String {
      switch self {
      case .replied: "Répondu"
      case .archived: "Archivée"
      case .reminded(let date): "De côté jusqu'à \(ConversationReminder(wakeAt: date).labelFR())"
      case .kept: "Gardée dans la file"
      }
    }

    var systemImage: String {
      switch self {
      case .replied: "checkmark"
      case .archived: "archivebox"
      case .reminded: "clock.arrow.circlepath"
      case .kept: "tray"
      }
    }
  }

  private struct Banner: Identifiable {
    let id = UUID()
    let conversationID: String
    let title: String
    let decision: Decision
    /// Où la page était : Annuler la remet là.
    let index: Int
  }

  private struct Tally {
    var replied = 0
    var archived = 0
    var reminded = 0
    var kept = 0
    var total: Int { replied + archived + reminded + kept }
  }

  var body: some View {
    Group {
      if line != nil {
        lineView
      } else {
        threshold
      }
    }
    .background(theme.paperSecondary.ignoresSafeArea())
    .toolbar(line == nil ? .visible : .hidden, for: .tabBar)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: line == nil)
    // Répondre est la sortie naturelle : l'envoi fait partir la page.
    .onChange(of: store.lastSent) { _, sent in
      guard let sent, line?.contains(sent.conversationID) == true else { return }
      decide(.replied(localID: sent.localID), for: sent.conversationID)
    }
    .task {
      // En démonstration, la ligne s'ouvre seule — une capture n'a pas de doigt.
      guard store.isDemo, DemoRelay.requestedScreen == .focus else { return }
      start()
    }
  }

  // MARK: - Le seuil

  private var threshold: some View {
    let queue = store.focusQueue
    return ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if queue.isEmpty {
          upToDate
        } else {
          Text("\(queue.count)")
            .font(Typography.letterHeading(typeface, 56))
            .foregroundStyle(theme.ink)
            .monospacedDigit()
          Text(queue.count == 1 ? "conversation attend" : "conversations attendent")
            .font(Typography.emptyState(typeface))
            .foregroundStyle(theme.inkSecondary)
            .padding(.top, -6)

          Picker("Vitesse", selection: $pass) {
            ForEach(FocusPass.allCases) { Text($0.labelFR).tag($0) }
          }
          .pickerStyle(.segmented)
          .padding(.top, Spacing.sm)
          Text(pass == .reply
               ? "Chaque conversation avec son composer. Répondre la fait sortir."
               : "Sans composer : Archiver, Rappel ou Garder. Pour répondre plus tard, au Mac.")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)

          VStack(spacing: 0) {
            ForEach(queue) { conversation in
              Button {
                start(at: conversation.id)
              } label: {
                thresholdRow(conversation)
              }
              .buttonStyle(.plain)
              .accessibilityHint("Commence la ligne à cette conversation")
              if conversation.id != queue.last?.id {
                Divider().overlay(theme.edge.opacity(0.6)).padding(.leading, 44)
              }
            }
          }
          .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.paper)
          )
          .padding(.top, Spacing.sm)

          Button {
            start()
          } label: {
            Text("Commencer")
              .font(Typography.body(typeface, size: 16))
              .fontWeight(.semibold)
              .foregroundStyle(theme.accentInk)
              .padding(.horizontal, 22)
              .padding(.vertical, 12)
              .background(Capsule().fill(theme.accentFill))
          }
          .buttonStyle(.plain)
          .padding(.top, Spacing.md)
          .accessibilityLabel("Commencer, \(pass.labelFR)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.xl)
      .padding(.bottom, Spacing.lg)
    }
    .background(theme.paper.ignoresSafeArea())
  }

  private func thresholdRow(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.sm) {
      ConversationAvatar(conversation: conversation, size: 30, theme: theme)
      Text(conversation.title)
        .font(Typography.body(typeface, size: 15))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Spacer(minLength: 6)
      Text(shortReason(conversation))
        .font(Typography.meta(typeface))
        .monospacedDigit()
        .foregroundStyle(theme.inkTertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
  }

  /// Le bilan, ou la file vide.
  private var upToDate: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Image(systemName: "checkmark.seal")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(theme.accent.opacity(0.8))
      Text("Vous êtes à jour")
        .font(Typography.letterHeading(typeface, 26))
        .foregroundStyle(theme.ink)
      if tally.total > 0 {
        Text(tallyLine)
          .font(Typography.emptyState(typeface))
          .foregroundStyle(theme.inkSecondary)
      } else {
        Text("La file est vide. Rien n'attend de réponse.")
          .font(Typography.emptyState(typeface))
          .foregroundStyle(theme.inkSecondary)
      }
    }
    .padding(.top, Spacing.lg)
    .accessibilityElement(children: .combine)
  }

  private var tallyLine: String {
    var parts: [String] = []
    if tally.replied > 0 { parts.append(tally.replied == 1 ? "1 réponse" : "\(tally.replied) réponses") }
    if tally.archived > 0 { parts.append(tally.archived == 1 ? "1 archivée" : "\(tally.archived) archivées") }
    if tally.reminded > 0 { parts.append(tally.reminded == 1 ? "1 rappel" : "\(tally.reminded) rappels") }
    if tally.kept > 0 { parts.append(tally.kept == 1 ? "1 gardée" : "\(tally.kept) gardées") }
    return parts.joined(separator: " · ")
  }

  // MARK: - La ligne

  private var lineView: some View {
    let ids = line ?? []
    return VStack(spacing: 0) {
      topline(ids)
      if ids.isEmpty {
        finished
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
              page(id)
                .containerRelativeFrame(.vertical)
                .id(id)
            }
          }
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        .overlay(alignment: .top) {
          if let banner { bannerView(banner) }
        }
      }
    }
  }

  private func topline(_ ids: [String]) -> some View {
    HStack {
      Button("Terminer") { finish() }
        .font(Typography.body(typeface, size: 15))
        .foregroundStyle(theme.accent)
      Spacer()
      if let currentID, let index = ids.firstIndex(of: currentID),
         let conversation = store.conversation(currentID) {
        HStack(spacing: 4) {
          Text(conversation.title)
            .fontWeight(.semibold)
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          Text("· \(index + 1) sur \(ids.count)")
            .foregroundStyle(theme.inkTertiary)
            .monospacedDigit()
        }
        .font(Typography.meta(typeface))
      }
      Spacer()
      // De quoi équilibrer « Terminer » : le titre reste au centre.
      Text("Terminer").font(Typography.body(typeface, size: 15)).hidden()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
  }

  @ViewBuilder
  private func page(_ id: String) -> some View {
    if let conversation = store.conversation(id) {
      VStack(spacing: 0) {
        pageHeader(conversation)
        ThreadView(
          conversationID: id,
          showsHeader: false,
          showsComposer: pass == .reply,
          foldsToPending: true,
          accessory: AnyView(actionRow(id))
        )
      }
      .background(theme.paper)
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .padding(.horizontal, 8)
      .padding(.top, 4)
      .padding(.bottom, 10)
    }
  }

  private func pageHeader(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.sm) {
      ConversationAvatar(conversation: conversation, size: 36, theme: theme)
      VStack(alignment: .leading, spacing: 1) {
        Text(conversation.title)
          .font(Typography.letterHeading(typeface, 17))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Text(reason(conversation))
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 6)
      Text(conversation.network.labelFR)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(theme.edge))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .accessibilityElement(children: .combine)
  }

  /// Pourquoi ce fil est là — écrit sur la page, pour décider avant de lire.
  private func reason(_ conversation: Conversation) -> String {
    var parts: [String] = []
    if conversation.unreadCount > 0 {
      parts.append(conversation.unreadCount == 1 ? "1 message non lu" : "\(conversation.unreadCount) messages non lus")
    } else if !conversation.lastMessageIsFromMe {
      parts.append("sans réponse")
    } else if !store.draftText(conversation.id).trimmingCharacters(in: .whitespaces).isEmpty {
      parts.append("brouillon en cours")
    } else {
      parts.append("dernier mot à vous")
    }
    parts.append("depuis \(ConversationRow.shortDate(conversation.lastMessageAt))")
    return parts.joined(separator: " · ")
  }

  private func shortReason(_ conversation: Conversation) -> String {
    let when = ConversationRow.shortDate(conversation.lastMessageAt)
    if conversation.unreadCount > 0 { return "\(conversation.unreadCount) · \(when)" }
    if !store.draftText(conversation.id).trimmingCharacters(in: .whitespaces).isEmpty { return "brouillon" }
    return when
  }

  // MARK: - Les décisions

  /// Trois boutons, à la même place sur chaque page. Jamais un geste.
  private func actionRow(_ id: String) -> some View {
    HStack(spacing: 6) {
      actionButton("Archiver", systemImage: "archivebox") {
        decide(.archived, for: id)
      }
      Menu {
        ForEach(ConversationReminder.suggestions()) { suggestion in
          Button(suggestion.title) { decide(.reminded(suggestion.date), for: id) }
        }
      } label: {
        actionLabel("Rappel", systemImage: "clock.arrow.circlepath")
      }
      .accessibilityLabel("Me le rappeler")
      actionButton(pass == .reply ? "Passer" : "Garder", systemImage: "chevron.down.2") {
        decide(.kept, for: id)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.top, 6)
    .padding(.bottom, pass == .reply ? 2 : Spacing.sm)
    .background(theme.paper)
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      actionLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.plain)
  }

  private func actionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(Typography.meta(typeface))
      .fontWeight(.medium)
      .foregroundStyle(theme.inkSecondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 9)
      .background(Capsule().fill(theme.paperSecondary.opacity(0.8)))
      .overlay(Capsule().strokeBorder(theme.edge.opacity(0.6)))
      .contentShape(Capsule())
  }

  private func decide(_ decision: Decision, for id: String) {
    guard var ids = line, let index = ids.firstIndex(of: id) else { return }
    switch decision {
    case .archived:
      store.setArchived(true, conversationID: id)
      // Un envoi peut être en sursis : l'annuler devra rendre le fil à la file.
      store.noteArchivedPendingSend(conversationID: id)
      tally.archived += 1
    case .reminded(let date):
      store.setReminder(date, conversationID: id)
      tally.reminded += 1
    case .replied:
      tally.replied += 1
    case .kept:
      tally.kept += 1
    }
    let title = store.conversation(id)?.title ?? ""
    ids.remove(at: index)
    // La suivante prend la place ; en bout de ligne, la précédente.
    let next = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
      if currentID == id { currentID = next }
      line = ids
    }
    show(Banner(conversationID: id, title: title, decision: decision, index: index))
  }

  private func show(_ banner: Banner) {
    bannerTask?.cancel()
    withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { self.banner = banner }
    bannerTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, self.banner?.id == banner.id else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { self.banner = nil }
    }
  }

  private func undo(_ banner: Banner) {
    switch banner.decision {
    case .archived:
      store.setArchived(false, conversationID: banner.conversationID)
      tally.archived -= 1
    case .reminded:
      store.setReminder(nil, conversationID: banner.conversationID)
      tally.reminded -= 1
    case .replied(let localID):
      if store.canUndoSend(localID) { store.undoSend(localID) }
      tally.replied -= 1
    case .kept:
      tally.kept -= 1
    }
    var ids = line ?? []
    if !ids.contains(banner.conversationID) {
      ids.insert(banner.conversationID, at: min(banner.index, ids.count))
    }
    bannerTask?.cancel()
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
      line = ids
      currentID = banner.conversationID
      self.banner = nil
    }
  }

  private func bannerView(_ banner: Banner) -> some View {
    let canUndo: Bool = {
      if case .replied(let localID) = banner.decision { return store.canUndoSend(localID) }
      return true
    }()
    return HStack(spacing: 8) {
      Image(systemName: banner.decision.systemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.accent)
      Text(banner.decision.labelFR)
        .fontWeight(.semibold)
        .foregroundStyle(theme.ink)
      Text("· \(banner.title)")
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
      Spacer(minLength: 6)
      if canUndo {
        Button("Annuler") { undo(banner) }
          .fontWeight(.medium)
          .foregroundStyle(theme.accent)
      }
    }
    .font(Typography.meta(typeface))
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 10)
    .glassSurface(cornerRadius: 22, fallbackFill: theme.paper, border: theme.edge, isInteractive: true)
    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10, y: 3)
    .padding(.horizontal, Spacing.md)
    .padding(.top, 10)
    .transition(.move(edge: .top).combined(with: .opacity))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(banner.decision.labelFR), \(banner.title)")
  }

  /// La ligne vidée : le bilan, et retour au seuil.
  private var finished: some View {
    VStack(spacing: Spacing.sm) {
      upToDate
      Button("Retour") { finish() }
        .font(Typography.body(typeface, size: 15))
        .foregroundStyle(theme.accent)
        .padding(.top, Spacing.sm)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, Spacing.lg)
    .background(theme.paper)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(.horizontal, 8)
    .padding(.bottom, 10)
  }

  // MARK: - Entrer, sortir

  private func start(at id: String? = nil) {
    let ids = store.focusQueue.map(\.id)
    guard !ids.isEmpty else { return }
    tally = Tally()
    banner = nil
    currentID = id.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    store.focusConversationID = currentID
    line = ids
  }

  private func finish() {
    bannerTask?.cancel()
    banner = nil
    line = nil
    currentID = nil
  }
}
