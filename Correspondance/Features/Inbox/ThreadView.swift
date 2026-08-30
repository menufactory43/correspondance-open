import AppKit
import SwiftUI

struct ThreadView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var isShowingThread = false

  private var theme: WritingTheme { themes.theme }

  private var sendLaterPickerPresented: Binding<Bool> {
    Binding(
      get: { store.sendLaterPicker != nil },
      set: { if !$0 { store.sendLaterPicker = nil } }
    )
  }

  var body: some View {
    Group {
      if store.selectedConversation != nil {
        VStack(spacing: 0) {
          if store.isThreadSearchActive {
            ThreadSearchBar(theme: theme, typeface: themes.typeface)
          }
          messages
          if let quoted = store.replyingToMessage {
            ReplyBanner(message: quoted, theme: theme, typeface: themes.typeface)
          }
          if let config = store.sendLaterConfig {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
          }
          ComposerBar(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            isScheduling: store.sendLaterConfig != nil,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSendLater: { store.toggleSendLaterPicker() },
            onSend: { Task { await store.sendDraft() } }
          )
          .popover(isPresented: sendLaterPickerPresented, arrowEdge: .top) {
            SendLaterPicker()
          }
        }
      } else {
        Text("Aucune conversation")
          .font(Typography.emptyState(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(theme.paper)
  }

  /// Le fil ne montre plus une bulle isolée par message : les prises de parole
  /// consécutives se serrent, le nom ne s'écrit qu'une fois, l'heure ne revient
  /// qu'après un silence. Cf. `MessageGrouping`.
  private var messageGroups: [MessageGroup] {
    MessageGrouping.groups(
      for: store.messages,
      showsSenderNames: store.selectedConversation?.isGroup == true,
      // Fil fusionné : le séparateur d'heure dit sur quel réseau on repart.
      showsNetworkOrigin: isMergedThread
    )
  }

  private var isMergedThread: Bool {
    guard let id = store.selectedConversationID else { return false }
    return store.isMerged(id)
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: ThreadMetrics.interGroupSpacing) {
          ForEach(messageGroups) { group in
            if let stamp = group.timeSeparator {
              ThreadTimeSeparator(
                date: stamp,
                network: group.networkOrigin,
                theme: theme,
                typeface: themes.typeface
              )
            }
            VStack(alignment: .leading, spacing: ThreadMetrics.intraGroupSpacing) {
              if let label = group.senderLabel {
                Text(label)
                  .font(Typography.meta(themes.typeface))
                  .foregroundStyle(theme.inkSecondary)
                  .lineLimit(1)
                  .padding(.leading, ThreadMetrics.senderLabelLeading)
              }
              ForEach(group.messages) { message in
                if let event = message.systemEventText {
                  ThreadEventSeparator(text: event, theme: theme, typeface: themes.typeface)
                    .id(message.id)
                } else {
                  bubble(for: message)
                    .id(message.id)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          if let delivery = store.selectedConversation?.lastDelivery,
             store.messages.last?.isFromMe == true
          {
            DeliveryReceiptLabel(delivery: delivery, theme: theme, typeface: themes.typeface)
          }

          // Ce qui partira plus tard attend en bas du fil, en pointillé.
          ForEach(store.scheduledForSelection) { scheduled in
            ScheduledMessageRow(message: scheduled, theme: theme, typeface: themes.typeface)
              .id("scheduled-\(scheduled.id)")
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
      // `contentMargins` s'AJOUTE à la zone sûre de la barre d'outils — inutile
      // d'y recompter la hauteur du titre.
      .contentMargins(.top, ThreadMetrics.topClearance, for: .scrollContent)
      .defaultScrollAnchor(.bottom)
      .overlay(alignment: .top) { TopScrollFade(theme: theme) }
      // TODO(macOS 27) : réduire la barre d'outils au défilement vers le bas.
      // .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
      .opacity(isShowingThread ? 1 : 0)
      // Cliquer dans le fil vaut lecture. `simultaneousGesture` pour ne rien
      // voler à la sélection de texte ni aux liens des bulles.
      .simultaneousGesture(TapGesture().onEnded { store.confirmSelectionAsRead() })
      .onAppear { pinToBottom(proxy) }
      .onChange(of: store.messages.count) { _, _ in
        pinToBottom(proxy)
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        isShowingThread = false
        pinToBottom(proxy)
      }
      .onChange(of: store.threadSearchCurrentID) { _, target in
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(target, anchor: .center)
        }
      }
    }
  }

  /// Une bulle et tout ce qu'on peut lui faire. Extraite de la boucle : le
  /// vérificateur de types s'y perdait.
  private func bubble(for message: ChatMessage) -> some View {
    let automatable = automationAvailable(for: message)
    let onEdit: ((String) -> Void)? = automatable
      ? { newText in Task { await store.editMessageViaAutomation(messageID: message.id, newText: newText) } }
      : nil
    let onUndoSend: (() -> Void)? = automatable
      ? { Task { await store.undoSendViaAutomation(messageID: message.id) } }
      : nil
    return MessageBubbleView(
      message: message,
      theme: theme,
      typeface: themes.typeface,
      highlightQuery: store.isThreadSearchActive ? store.threadSearchQuery : "",
      isCurrentMatch: store.threadSearchCurrentID == message.id,
      isSelected: store.selectedMessageID == message.id,
      onReact: { emoji in
        Task { await store.react(messageID: message.id, emoji: emoji) }
      },
      onSelect: {
        store.selectMessage(store.selectedMessageID == message.id ? nil : message.id)
      },
      onReply: {
        store.selectMessage(message.id)
        store.replyToSelectedMessage()
      },
      onEdit: onEdit,
      onUndoSend: onUndoSend
    )
  }

  /// « Modifier » et « Annuler l'envoi » n'ont de sens que sur mes iMessages,
  /// et seulement quand l'automatisation Messages est active et saine.
  private func automationAvailable(for message: ChatMessage) -> Bool {
    message.network == .iMessage && message.isFromMe && store.canAutomateMessages
  }

  private func pinToBottom(_ proxy: ScrollViewProxy) {
    let target = store.messages.last?.id
    if let target {
      proxy.scrollTo(target, anchor: .bottom)
    }
    DispatchQueue.main.async {
      if let id = store.messages.last?.id {
        proxy.scrollTo(id, anchor: .bottom)
      }
      isShowingThread = true
    }
  }
}

enum ThreadMetrics {
  /// Deux bulles d'une même prise de parole se touchent presque…
  static let intraGroupSpacing: CGFloat = 2
  /// …et l'on ne respire qu'entre deux prises de parole.
  static let interGroupSpacing: CGFloat = 12
  /// Le nom s'aligne sur le texte de la bulle, pas sur son bord.
  static let senderLabelLeading: CGFloat = 16
  /// Air au-dessus du premier message, en plus de la zone sûre de la barre
  /// d'outils que le système fournit déjà.
  static let topClearance: CGFloat = 16
  /// Hauteur de la bande où le fil se dissout sous la barre d'outils.
  static let topFadeHeight: CGFloat = 64
}

/// Séparateur horaire centré, discret — comme Messages : on ne redate que
/// lorsque la conversation a repris après un silence, jamais sous chaque bulle.
struct ThreadTimeSeparator: View {
  let date: Date
  /// Sur un fil fusionné : le réseau d'où repart la suite (« 15:48 · iMessage »).
  var network: MessageNetwork?
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
      if let network {
        Text("·")
        Image(systemName: network.systemImage)
          .font(.system(size: 9, weight: .semibold))
        Text(network.labelFR)
      }
    }
    .font(Typography.meta(typeface))
    .foregroundStyle(theme.inkTertiary)
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.xxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      network.map { "Reprise de la conversation sur \($0.labelFR), \(label)" }
        ?? "Reprise de la conversation, \(label)"
    )
  }

  /// Aujourd'hui : l'heure suffit. Plus loin : il faut aussi le jour, sinon
  /// « 09:12 » ne dit pas si c'était ce matin ou l'an dernier.
  private var label: String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInYesterday(date) { return "Hier \(time)" }
    if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
      return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
    }
    return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
  }
}

/// Événement de conversation (« X a ajouté Y », renommage, départ) : une ligne
/// centrée, du même gris que les horodatages — présente, jamais bavarde.
struct ThreadEventSeparator: View {
  let text: String
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    Text(text)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.xxs)
      .accessibilityLabel(text)
  }
}

/// Barre ⌘F du fil : champ, compteur, précédent / suivant, Échap pour fermer.
private struct ThreadSearchBar: View {
  @Environment(InboxStore.self) private var store
  let theme: WritingTheme
  let typeface: WritingTypeface
  @FocusState private var isFocused: Bool

  private var countLabel: String {
    let total = store.threadSearchMatchIDs.count
    guard total > 0 else {
      return store.threadSearchQuery.isEmpty ? "" : "Aucun résultat"
    }
    return "\(store.threadSearchCursor + 1) sur \(total)"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(theme.inkTertiary)

      TextField("Rechercher dans le fil", text: Bindable(store).threadSearchQuery)
        .textFieldStyle(.plain)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .focused($isFocused)
        .onKeyPress(.escape) {
          store.closeThreadSearch()
          return .handled
        }
        .onKeyPress(.return) {
          if NSEvent.modifierFlags.contains(.shift) {
            store.threadSearchPrevious()
          } else {
            store.threadSearchNext()
          }
          return .handled
        }

      Text(countLabel)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .monospacedDigit()

      Button { store.threadSearchPrevious() } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat précédent")

      Button { store.threadSearchNext() } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat suivant")

      Button { store.closeThreadSearch() } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Fermer la recherche")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 11, weight: .semibold))
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 7)
    .background(theme.paperSecondary)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.edge).frame(height: 1)
    }
    .onAppear { isFocused = true }
  }
}

/// Bandeau « en réponse à… » au-dessus du composer, avec sa croix pour annuler.
private struct ReplyBanner: View {
  @Environment(InboxStore.self) private var store
  let message: ChatMessage
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(theme.accent)
        .frame(width: 2, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(message.isFromMe ? "Réponse à moi-même" : "En réponse à \(message.senderID ?? "ce message")")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.sidebarPreviewText)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button { store.cancelReply() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Annuler la citation")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
    .background(theme.paperSecondary)
  }
}

/// Coche d'acheminement sous le dernier message sortant.
///
/// iMessage la donne complète (`is_delivered` / `is_read`). WhatsApp ne bridge que la
/// **lecture** : on y montre « Envoyé » ou « Vu », jamais « Livré ». Signal ne bridge
/// aucun accusé de livraison — rien ne s'affiche.
private struct DeliveryReceiptLabel: View {
  let delivery: MessageDelivery
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: delivery.systemImage)
        .font(.system(size: 9))
      Text(delivery.labelFR)
        .font(Typography.meta(typeface))
    }
    .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 4)
    .accessibilityLabel("Dernier message : \(delivery.labelFR)")
  }
}
