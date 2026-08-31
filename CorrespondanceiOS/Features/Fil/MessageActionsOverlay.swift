import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Ce qui s'ouvre sur un appui long : la bulle, seule sur un fond de verre,
/// les smileys au-dessus d'elle (les six réactions rapides et un **+** pour
/// tous les autres), et en dessous la liste des actions — répondre, modifier,
/// copier, supprimer. Le geste de Messages et de WhatsApp, sans menu système :
/// le `contextMenu` de SwiftUI ne sait pas coiffer son aperçu d'une rangée.
struct MessageActionsOverlay: View {
  let message: ChatMessage
  let conversationID: String
  var senderLabel: String?
  let onDismiss: () -> Void

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var isPickingEmoji = false
  @State private var pendingDeletion = false
  @State private var hasAppeared = false

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }
  private var side: HorizontalAlignment { message.isFromMe ? .trailing : .leading }
  private var sideAlignment: Alignment { message.isFromMe ? .trailing : .leading }

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .ignoresSafeArea()
        .onTapGesture { close() }
        .accessibilityLabel("Fermer les actions du message")
        .accessibilityAddTraits(.isButton)

      VStack(alignment: side, spacing: 10) {
        reactionRow
        bubble
        actions
      }
      .padding(.horizontal, Spacing.md)
      .frame(maxWidth: .infinity, alignment: sideAlignment)
      .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94)
      .opacity(hasAppeared || reduceMotion ? 1 : 0)
    }
    .onAppear {
      withAnimation(.spring(duration: 0.28, bounce: 0.2)) { hasAppeared = true }
    }
    .sheet(isPresented: $isPickingEmoji) {
      EmojiPickerSheet(current: message.myReactionEmoji) { emoji in
        react(emoji)
      }
      .environment(themes)
    }
    .alert("Supprimer ce message pour tout le monde ?", isPresented: $pendingDeletion) {
      Button("Supprimer", role: .destructive) {
        let fil = conversationID
        let bulle = message.id
        Task { @MainActor in await store.deleteEverywhere(messageID: bulle, conversationID: fil) }
        close()
      }
      Button("Annuler", role: .cancel) { close() }
    } message: {
      Text("Il disparaît du fil, chez toi comme chez ton correspondant. C'est sans retour.")
    }
  }

  // MARK: - Les smileys

  private var reactionRow: some View {
    HStack(spacing: 2) {
      ForEach(RelayStore.quickReactions, id: \.self) { emoji in
        let mine = message.myReactionEmoji == emoji
        Button {
          react(emoji)
        } label: {
          Text(emoji)
            .font(.system(size: 26))
            .frame(width: 40, height: 40)
            .background(Circle().fill(mine ? theme.selection : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mine ? "Retirer la réaction \(emoji)" : "Réagir \(emoji)")
      }
      Button {
        isPickingEmoji = true
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(theme.inkSecondary)
          .frame(width: 34, height: 34)
          .background(Circle().fill(theme.paperSecondary))
      }
      .buttonStyle(.plain)
      .padding(.leading, 2)
      .accessibilityLabel("Un autre emoji")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .glassSurface(cornerRadius: 26, fallbackFill: theme.sidebar, border: theme.edge)
  }

  // MARK: - La bulle

  /// La bulle telle qu'elle est dans le fil, inerte. Trop haute pour l'écran,
  /// elle est coupée au bas de son cadre plutôt que de pousser les actions dehors.
  private var bubble: some View {
    MessageBubble(
      message: message,
      theme: theme,
      typeface: typeface,
      senderLabel: senderLabel,
      showsLinkPreviews: false
    )
    .allowsHitTesting(false)
    .fixedSize(horizontal: false, vertical: true)
    // `frame(maxHeight:)` s'étirerait jusqu'au plafond : on mesure, on borne.
    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bubbleHeight = $0 }
    .frame(height: bubbleHeight.map { min($0, 300) }, alignment: .top)
    .clipped()
  }

  @State private var bubbleHeight: CGFloat?

  // MARK: - Les actions

  private var actions: some View {
    VStack(spacing: 0) {
      action("Répondre en citant", systemImage: "arrowshape.turn.up.left") {
        store.setReplyTarget(message.id, conversationID: conversationID)
        close()
      }
      if store.canEdit(message) {
        divider
        action("Modifier…", systemImage: "pencil") {
          store.beginEditing(message, conversationID: conversationID)
          close()
        }
      }
      if store.canForward(message) {
        divider
        action("Transférer…", systemImage: "arrowshape.turn.up.right") {
          store.beginForwarding(message)
          close()
        }
      }
      if !message.text.isEmpty {
        divider
        action("Copier le texte", systemImage: "doc.on.doc") {
          Platform.copyToPasteboard(message.text)
          close()
        }
      }
      if message.isFromMe {
        divider
        action("Supprimer pour tout le monde…", systemImage: "trash", destructive: true) {
          pendingDeletion = true
        }
      }
      divider
      action("Supprimer ici", systemImage: "eye.slash", destructive: true) {
        store.hide(messageID: message.id, conversationID: conversationID)
        close()
      }
    }
    .frame(width: 260)
    .glassSurface(cornerRadius: 16, fallbackFill: theme.sidebar, border: theme.edge)
  }

  private var divider: some View {
    Divider().overlay(theme.edge.opacity(0.6))
  }

  private func action(
    _ title: String,
    systemImage: String,
    destructive: Bool = false,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      HStack {
        Text(title)
          .font(Typography.body(typeface, size: 16))
        Spacer(minLength: 12)
        Image(systemName: systemImage)
          .font(.system(size: 15))
      }
      .foregroundStyle(destructive ? Color.red : theme.ink)
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Faire

  private func react(_ emoji: String) {
    let fil = conversationID
    let bulle = message.id
    Task { @MainActor in await store.react(conversationID: fil, messageID: bulle, emoji: emoji) }
    close()
  }

  private func close() {
    if reduceMotion { onDismiss(); return }
    withAnimation(.easeOut(duration: 0.18)) { onDismiss() }
  }
}

/// Tous les autres emoji, quand les six rapides ne suffisent pas : une grille
/// par famille, et un champ pour taper celui qu'on a en tête.
struct EmojiPickerSheet: View {
  var current: String?
  let onPick: (String) -> Void

  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss
  @State private var typed = ""

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private static let families: [(String, [String])] = [
    ("Visages", ["😀", "😁", "😂", "🤣", "😊", "😍", "🥰", "😘", "😎", "🤩", "🥳", "😏", "😅", "😉", "🙂", "🤔",
                 "🤨", "😐", "🙄", "😬", "😴", "🤯", "😳", "🥺", "😢", "😭", "😤", "😡", "🤬", "🤮", "🤒", "🤗",
                 "🤭", "🤫", "🤐", "😇", "🥲", "😱", "😈", "💀", "🤡", "👻", "👽", "🤖"]),
    ("Gestes", ["👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "🤙", "👋", "🙌", "👏", "🙏", "💪", "✊", "👊", "🫶",
                "🤝", "☝️", "👆", "👇", "👈", "👉", "🖐️", "✋", "🫡", "🤌"]),
    ("Cœurs", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "💕", "💞", "💓", "💗", "💖",
               "💘", "💝", "💯", "✨", "⭐", "🌟", "🔥", "💥", "💫", "🎉", "🎊", "🎈", "🎁", "🏆"]),
    ("Animaux", ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
                 "🐧", "🐦", "🦆", "🦉", "🐝", "🦋", "🐌", "🐢", "🐍", "🐙", "🦀", "🐳", "🦄", "🐘"]),
    ("À table", ["🍏", "🍎", "🍋", "🍌", "🍉", "🍇", "🍓", "🍒", "🥑", "🌽", "🥐", "🥖", "🧀", "🍕", "🍔", "🍟",
                 "🌮", "🍣", "🍜", "🍩", "🍪", "🎂", "🍰", "🍫", "🍿", "☕", "🍵", "🍺", "🍷", "🥂"]),
    ("Autour", ["⚽", "🏀", "🎾", "🏓", "🎮", "🎲", "🎸", "🎧", "🎬", "📷", "💻", "📱", "✈️", "🚗", "🚲", "⛵",
                "🏠", "🌍", "🌈", "☀️", "🌙", "⛄", "🌧️", "🌸", "🌻", "🌲", "🍀", "💡", "📚", "✏️"]),
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.md, pinnedViews: []) {
          typedField
          ForEach(Self.families, id: \.0) { family in
            VStack(alignment: .leading, spacing: 6) {
              Text(family.0)
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.inkTertiary)
                .padding(.horizontal, 4)
              LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(family.1, id: \.self) { emoji in
                  Button {
                    pick(emoji)
                  } label: {
                    Text(emoji)
                      .font(.system(size: 28))
                      .frame(maxWidth: .infinity, minHeight: 40)
                      .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                          .fill(current == emoji ? theme.selection : .clear)
                      )
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(current == emoji ? "Retirer la réaction \(emoji)" : "Réagir \(emoji)")
                }
              }
            }
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
      }
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Réagir")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .presentationDetents([.medium, .large])
  }

  /// N'importe quel emoji du clavier : on garde le premier caractère tapé.
  private var typedField: some View {
    HStack(spacing: 8) {
      TextField(
        "",
        text: $typed,
        prompt: Text("Un autre emoji, au clavier").foregroundStyle(theme.inkTertiary)
      )
      .font(Typography.composer(typeface))
      .foregroundStyle(theme.ink)
      .autocorrectionDisabled()
      .onSubmit { useTyped() }
      if let first = typedEmoji {
        Button("Réagir \(first)") { useTyped() }
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.paperSecondary.opacity(0.7))
    )
  }

  private var typedEmoji: String? {
    guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first,
          first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C })
    else { return nil }
    return String(first)
  }

  private func useTyped() {
    guard let emoji = typedEmoji else { return }
    pick(emoji)
  }

  private func pick(_ emoji: String) {
    dismiss()
    onPick(emoji)
  }
}
