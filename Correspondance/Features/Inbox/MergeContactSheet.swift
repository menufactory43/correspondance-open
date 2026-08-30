import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// « Fusionner ces chats ? » — la feuille où l'on décide d'un nom, d'un visage
/// et d'un réseau par défaut avant que deux fils n'en deviennent un.
///
/// Rien d'irréversible : « Séparer », dans la fiche du contact, défait tout.
struct MergeContactSheet: View {
  let candidates: [Conversation]
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var title = ""
  @State private var avatarConversationID: String?
  @State private var defaultConversationID = ""
  @State private var isEditingTitle = false
  @FocusState private var isTitleFocused: Bool

  /// Le fil dont on emprunte le visage — celui choisi, sinon le premier.
  private var avatarConversation: Conversation? {
    candidates.first { $0.id == avatarConversationID } ?? candidates.first
  }

  var body: some View {
    VStack(spacing: Spacing.md) {
      if let avatarConversation {
        ConversationAvatarView(conversation: avatarConversation, size: 76, theme: theme)
      }

      nameField

      // Le visage du contact fusionné : l'un de ceux qu'on avait déjà.
      HStack(spacing: Spacing.sm) {
        ForEach(candidates) { conversation in
          Button {
            avatarConversationID = conversation.id
          } label: {
            ConversationAvatarView(conversation: conversation, size: 34, theme: theme)
              .overlay(
                Circle().strokeBorder(
                  theme.accent,
                  lineWidth: conversation.id == avatarConversation?.id ? 2 : 0
                )
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Utiliser l'avatar \(conversation.network.labelFR)")
        }
      }

      Picker("Chat par défaut", selection: $defaultConversationID) {
        ForEach(candidates) { conversation in
          Label(conversation.network.labelFR, systemImage: conversation.network.systemImage)
            .tag(conversation.id)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 260)

      Text("Les deux fils se liront ensemble, du plus ancien au plus récent. "
        + "Le chat par défaut est celui où part le prochain message.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Retour") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Fusionner \(candidates.count) chats") {
          let toMerge = candidates
          let chosenTitle = title
          let avatar = avatarConversationID
          let byDefault = defaultConversationID
          dismiss()
          Task {
            await store.merge(
              toMerge,
              title: chosenTitle,
              avatarConversationID: avatar,
              defaultConversationID: byDefault
            )
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(Spacing.lg)
    .frame(width: 340)
    .onAppear(perform: prime)
  }

  private var nameField: some View {
    HStack(spacing: 6) {
      if isEditingTitle {
        TextField("Nom", text: $title)
          .textFieldStyle(.roundedBorder)
          .focused($isTitleFocused)
          .onSubmit { isEditingTitle = false }
      } else {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .lineLimit(1)
        Button {
          isEditingTitle = true
          isTitleFocused = true
        } label: {
          Image(systemName: "pencil")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Renommer le contact")
      }
    }
    .frame(maxWidth: 260)
  }

  /// Le meilleur nom qu'on ait déjà, et iMessage comme chat par défaut quand il
  /// est de la partie — sinon le réseau du dernier message reçu.
  private func prime() {
    guard defaultConversationID.isEmpty else { return }
    title = candidates.first { !$0.hasPlaceholderTitle }?.title
      ?? candidates.first?.title
      ?? "Contact"
    avatarConversationID = candidates.first { !$0.hasPlaceholderTitle }?.id ?? candidates.first?.id
    defaultConversationID = candidates.first { $0.network == .iMessage }?.id
      ?? candidates.max(by: { $0.lastMessageAt < $1.lastMessageAt })?.id
      ?? candidates.first?.id
      ?? ""
  }
}

/// La proposition discrète sous la pilule : « 2 chats · Fusionner · ✕ ».
/// Elle ne s'impose jamais — le ✕ la fait taire pour de bon.
struct MergeSuggestionBar: View {
  let candidates: [Conversation]
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  @State private var isPresentingSheet = false

  var body: some View {
    HStack(spacing: 8) {
      Text("\(candidates.count) chats")
        .font(.system(size: 11, weight: .medium))
      HStack(spacing: 3) {
        ForEach(candidates) { conversation in
          Image(systemName: conversation.network.systemImage)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .accessibilityLabel(conversation.network.labelFR)
        }
      }
      Divider().frame(height: 12)
      Button("Fusionner") { isPresentingSheet = true }
        .buttonStyle(.link)
        .font(.system(size: 11, weight: .semibold))
      Button {
        store.dismissMergeCandidate(candidates)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tertiary)
      .accessibilityLabel("Ne plus proposer cette fusion")
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 5)
    .sheet(isPresented: $isPresentingSheet) {
      MergeContactSheet(candidates: candidates, theme: theme)
    }
  }
}
