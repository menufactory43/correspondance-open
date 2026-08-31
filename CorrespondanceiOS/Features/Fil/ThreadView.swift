import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Le fil d'une conversation.
///
/// La pilule de verre (photo + nom) au centre de la barre, entre le retour et
/// le menu ; elle ouvre la fiche du fil. Messages regroupés par
/// `MessageGrouping` comme sur le Mac — un nom par prise de parole, une heure
/// par silence de cinq minutes — et le composer en bas. L'accusé de lecture
/// part à l'ouverture, comme sur le Mac.
struct ThreadView: View {
  let conversationID: String
  /// En Focus, le fil se passe de son en-tête : la barre de Focus le porte déjà.
  var showsHeader = true

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var isShowingInfo = false
  /// La bulle sous appui long, et le nom qu'elle portait dans le fil.
  @State private var focused: FocusedMessage?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var conversation: Conversation? { store.conversation(conversationID) }

  private struct FocusedMessage: Equatable {
    var message: ChatMessage
    var senderLabel: String?
  }

  var body: some View {
    thread
      .background(theme.paper.ignoresSafeArea())
      .safeAreaInset(edge: .bottom, spacing: 0) {
        ThreadComposer(conversationID: conversationID)
      }
      .overlay {
        if let focused {
          MessageActionsOverlay(
            message: focused.message,
            conversationID: conversationID,
            senderLabel: focused.senderLabel
          ) {
            self.focused = nil
          }
          .transition(.opacity)
        }
      }
      .sensoryFeedback(.impact(weight: .medium), trigger: focused != nil) { _, new in new }
      // Le nom du fil est dans la pilule : la barre n'a pas de titre à elle.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
      .toolbar(focused == nil ? .visible : .hidden, for: .navigationBar)
      .toolbarBackground(.hidden, for: .navigationBar)
      .sheet(isPresented: $isShowingInfo) {
        ThreadInfoSheet(conversationID: conversationID)
          .environment(store)
          .environment(themes)
      }
      .task(id: conversationID) { await store.open(conversationID: conversationID) }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if showsHeader, let conversation {
      ToolbarItem(placement: .principal) {
        Button {
          isShowingInfo = true
        } label: {
          ThreadPillHeader(conversation: conversation, theme: theme, typeface: typeface)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre la fiche de la conversation")
      }
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button {
          store.toggleArchived(conversationID)
        } label: {
          Label(
            store.isArchived(conversationID) ? "Désarchiver" : "Archiver",
            systemImage: store.isArchived(conversationID) ? "tray.and.arrow.up" : "archivebox"
          )
        }
        Button {
          store.togglePinned(conversationID)
        } label: {
          Label(
            store.isPinned(conversationID) ? "Désépingler" : "Épingler",
            systemImage: store.isPinned(conversationID) ? "pin.slash" : "pin"
          )
        }
        Button {
          store.toggleMuted(conversationID)
        } label: {
          Label(
            store.isMuted(conversationID) ? "Réactiver les notifications" : "Mettre en muet",
            systemImage: store.isMuted(conversationID) ? "bell" : "bell.slash"
          )
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("Actions de la conversation")
    }
  }

  // MARK: - Le fil

  private var thread: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          Color.clear.frame(height: 4)

          ForEach(groups) { group in
            if let separator = group.timeSeparator {
              timeSeparator(separator, network: group.networkOrigin)
            }
            VStack(alignment: group.isFromMe ? .trailing : .leading, spacing: 3) {
              ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
                if let text = message.systemEventText {
                  systemEvent(text)
                } else {
                  MessageBubble(
                    message: message,
                    theme: theme,
                    typeface: typeface,
                    senderLabel: index == 0 ? group.senderLabel : nil,
                    onReply: { store.setReplyTarget(message.id, conversationID: conversationID) },
                    onVotePoll: message.poll == nil ? nil : { (answerID: String) in
                      let fil = conversationID
                      let bulle = message.id
                      Task { @MainActor in
                        await store.votePoll(conversationID: fil, messageID: bulle, answerID: answerID)
                      }
                    },
                    onReact: { emoji in
                      Task { await store.react(conversationID: conversationID, messageID: message.id, emoji: emoji) }
                    },
                    onLongPress: message.isAgentProposal ? nil : {
                      withAnimation(.easeOut(duration: 0.18)) {
                        focused = FocusedMessage(message: message, senderLabel: group.senderLabel)
                      }
                    },
                    onSendProposal: {
                      Task { await store.sendAgentProposal(message, conversationID: conversationID) }
                    },
                    onEditProposal: { store.editAgentProposal(message, conversationID: conversationID) },
                    onIgnoreProposal: { store.ignoreAgentProposal(message, conversationID: conversationID) }
                  )
                  .id(message.id)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: group.isFromMe ? .trailing : .leading)
          }

          // « Alice écrit… », au bas du fil, là où sa bulle apparaîtra.
          if let typing = store.typingLabel(conversationID) {
            Text(typing)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkTertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, 6)
              .transition(.opacity)
              .accessibilityLabel(typing)
          }

          if let receipt = readReceiptLabel {
            Text(receipt)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkTertiary)
              .frame(maxWidth: .infinity, alignment: .trailing)
              .padding(.trailing, 6)
              .accessibilityLabel("Dernier message \(receipt)")
          }

          Color.clear.frame(height: 8).id(Self.bottomAnchor)
        }
        .padding(.horizontal, Spacing.sm)
      }
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .onChange(of: messages.last?.id) { _, _ in
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
      }
    }
  }

  private static let bottomAnchor = "fil.bas"

  private var messages: [ChatMessage] { store.visibleMessages(conversationID) }
  private var groups: [MessageGroup] { store.groups(conversationID) }

  /// « Vu » sous le dernier message sortant — quand le réseau l'expose.
  /// Signal et WhatsApp ne le donnent pas : on n'affiche alors rien plutôt
  /// qu'un état inventé.
  private var readReceiptLabel: String? {
    guard let delivery = conversation?.lastDelivery,
          messages.last?.isFromMe == true
    else { return nil }
    return delivery.labelFR
  }

  private func timeSeparator(_ date: Date, network: MessageNetwork?) -> some View {
    let time = date.formatted(
      Calendar.current.isDateInToday(date)
        ? Date.FormatStyle().hour().minute()
        : Date.FormatStyle().day().month(.abbreviated).hour().minute()
    )
    return Text(network.map { "\(time) · \($0.labelFR)" } ?? time)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 8)
  }

  private func systemEvent(_ text: String) -> some View {
    Text(text)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 6)
  }
}

/// La pilule au centre de la barre : la photo du fil (mosaïque des membres
/// pour un groupe, pastille du réseau) et son nom, dans une capsule de verre.
struct ThreadPillHeader: View {
  let conversation: Conversation
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  var body: some View {
    HStack(spacing: 7) {
      ConversationAvatar(conversation: conversation, size: 26, theme: theme)
      Text(conversation.title)
        .font(Typography.body(typeface, size: 15))
        .fontWeight(.medium)
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .frame(maxWidth: 180)
    }
    .padding(.leading, 5)
    .padding(.trailing, 12)
    .padding(.vertical, 5)
    .glassSurface(cornerRadius: 18, fallbackFill: theme.sidebar, border: theme.edge, isInteractive: true)
    .contentShape(Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(conversation.title), \(conversation.network.labelFR)")
  }
}
