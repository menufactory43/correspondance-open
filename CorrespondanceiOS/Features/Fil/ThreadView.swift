import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Le fil d'une conversation.
///
/// En-tête flottant en verre (avatar + nom), messages regroupés par
/// `MessageGrouping` comme sur le Mac — un nom par prise de parole, une heure
/// par silence de cinq minutes — et le composer en bas. L'accusé de lecture
/// part à l'ouverture, comme sur le Mac.
struct ThreadView: View {
  let conversationID: String
  /// En Focus, le fil se passe de son en-tête : la barre de Focus le porte déjà.
  var showsHeader = true

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var conversation: Conversation? { store.conversation(conversationID) }

  var body: some View {
    ZStack(alignment: .top) {
      thread
      if showsHeader, let conversation {
        ThreadPillHeader(conversation: conversation, theme: theme, typeface: typeface)
          .padding(.horizontal, Spacing.md)
          .padding(.top, Spacing.xs)
      }
    }
    .background(theme.paper.ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ThreadComposer(conversationID: conversationID)
    }
    // Le nom du fil est déjà dans la pilule flottante : l'écrire aussi dans la
    // barre de navigation le dirait deux fois, à dix points d'écart.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .toolbarBackground(.hidden, for: .navigationBar)
    .task(id: conversationID) { await store.open(conversationID: conversationID) }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
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
          // De quoi passer sous l'en-tête flottant sans qu'il masque le premier
          // message quand le fil est court.
          Color.clear.frame(height: showsHeader ? 56 : 4)

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
                    onReact: { emoji in
                      Task { await store.react(conversationID: conversationID, messageID: message.id, emoji: emoji) }
                    },
                    onReply: { store.setReplyTarget(message.id, conversationID: conversationID) },
                    onHide: { store.hide(messageID: message.id, conversationID: conversationID) },
                    onDeleteEverywhere: message.isFromMe ? {
                      Task { await store.deleteEverywhere(messageID: message.id, conversationID: conversationID) }
                    } : nil,
                    onVotePoll: message.poll == nil ? nil : { (answerID: String) in
                      let fil = conversationID
                      let bulle = message.id
                      Task { @MainActor in
                        await store.votePoll(conversationID: fil, messageID: bulle, answerID: answerID)
                      }
                    }
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

/// L'en-tête flottant : une pilule de verre avec la photo et le nom du fil.
struct ThreadPillHeader: View {
  let conversation: Conversation
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  var body: some View {
    HStack(spacing: Spacing.xs) {
      ConversationAvatar(conversation: conversation, size: 28, theme: theme)
      VStack(alignment: .leading, spacing: 0) {
        Text(conversation.title)
          .font(Typography.body(typeface, size: 15))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Text(conversation.network.labelFR)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .glassSurface(cornerRadius: 22, fallbackFill: theme.sidebar, border: theme.edge)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(conversation.title), \(conversation.network.labelFR)")
  }
}
