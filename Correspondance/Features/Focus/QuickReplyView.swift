import AppKit
import SwiftUI
import CorrespondanceCore

/// La réponse rapide : le dernier de ce qui s'est dit, et de quoi répondre.
///
/// Le même papier, les mêmes encres et la même page que le Focus — jamais le
/// gris de `hudWindow`. On y arrive d'un raccourci, on en repart d'un Échap ou
/// d'un message envoyé.
struct QuickReplyView: View {
  let model: QuickReplyModel

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  private var conversation: Conversation? {
    model.conversationID.flatMap { store.conversationRow($0) }
  }

  private var session: ConversationSession? {
    model.conversationID.map { store.session(for: $0) }
  }

  var body: some View {
    GeometryReader { geometry in
      let metrics = FocusPageMetrics.resolve(width: geometry.size.width)
      ZStack {
        theme.paper
        if let conversation, let session {
          page(conversation: conversation, session: session, metrics: metrics)
        } else {
          Text("Rien à répondre pour l’instant.")
            .font(Typography.emptyState(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
            .padding(metrics.trailing)
        }
        if model.isShowingPicker {
          picker(metrics: metrics)
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(theme.edge.opacity(0.7), lineWidth: 1)
      }
    }
    .frame(minWidth: 240, minHeight: 180)
    // Le panneau porte encore une barre de titre (c'est elle qui autorise le
    // redimensionnement) : sans cela, `NSHostingView` en garderait la hauteur
    // en marge de sécurité, et une bande vide coifferait le papier.
    .ignoresSafeArea()
    // Le thème d'écriture vaut ici comme partout, et suit ses changements.
    .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
    .tint(theme.accent)
    .background {
      QuickReplyAppearance(isDark: theme.id.prefersDarkChrome)
        .frame(width: 0, height: 0)
    }
  }

  // MARK: - La page

  private func page(
    conversation: Conversation, session: ConversationSession, metrics: FocusPageMetrics
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(conversation, metrics: metrics)
      // Le fil ancré en bas : dans 320 points de haut, ce qu'on voit est
      // exactement le dernier groupe de messages.
      FocusTranscriptView(session: session, metrics: metrics, includesEditor: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // En post-it, le fil remonterait sous l'entête : il s'arrête à sa ligne.
        .clipped()
      FocusPageEditor(session: session, theme: theme) {
        QuickReplyPanelController.shared.noteSent()
      }
      .padding(.bottom, metrics.isCompact ? Spacing.xs : Spacing.sm)
    }
    .padding(.leading, metrics.leading)
    .padding(.trailing, metrics.trailing)
  }

  private func header(_ conversation: Conversation, metrics: FocusPageMetrics) -> some View {
    HStack(spacing: 6) {
      ConversationAvatarView(
        conversation: conversation, size: metrics.isCompact ? 16 : 20, theme: theme
      )
      Text(conversation.title)
        .font(.system(size: metrics.isCompact ? 12 : 13, weight: .semibold))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.85)
      if !metrics.isCompact {
        Text(conversation.network.labelFR)
          .font(.system(size: 11))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
          .layoutPriority(-1)
      }
      Spacer(minLength: 4)
      if !metrics.isCompact {
        Text("⌘K")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(theme.selection.opacity(0.6))
          )
          .accessibilityLabel("Changer de conversation")
      }
    }
    .padding(.top, metrics.isCompact ? Spacing.xs : Spacing.sm)
    .padding(.bottom, metrics.isCompact ? Spacing.xxs : Spacing.xs)
  }

  // MARK: - Mini-sélecteur (⌘K)

  private func picker(metrics: FocusPageMetrics) -> some View {
    let matches = Array(store.quickReplyMatches(model.query).prefix(24))
    return VStack(alignment: .leading, spacing: 0) {
      TextField("Aller à…", text: Bindable(model).query)
        .textFieldStyle(.plain)
        .font(Typography.composer(themes.typeface))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
      Divider().overlay(theme.edge)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(matches) { conversation in
            Button {
              model.choose(conversation.id)
              store.quickReplyBecameVisible(conversation.id)
            } label: {
              HStack(spacing: 8) {
                ConversationAvatarView(conversation: conversation, size: 20, theme: theme)
                Text(conversation.title)
                  .font(.system(size: 12))
                  .foregroundStyle(theme.ink)
                  .lineLimit(1)
                Spacer(minLength: 0)
                if conversation.unreadCount > 0 {
                  Text("\(conversation.unreadCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.paper)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent))
                }
              }
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 5)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 4)
      }
    }
    .background(theme.paperSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(metrics.isCompact ? Spacing.xxs : Spacing.xs)
    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
  }
}

/// L'apparence de la fenêtre elle-même suit le thème, comme partout ailleurs.
private struct QuickReplyAppearance: NSViewRepresentable {
  let isDark: Bool

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    let dark = isDark
    DispatchQueue.main.async {
      nsView.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }
}
