import SwiftUI

/// « Quand ? » — le sélecteur d'heure d'envoi (⌘⇧L), en popover sur le composer.
///
/// Comme chez Beeper : un champ libre qui comprend « demain 9h » ou « lundi
/// matin », des raccourcis quand il est vide, et l'option relance-si-silence.
struct SendLaterPicker: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var query = ""
  @State private var onlyIfNoReply = false
  @FocusState private var isFieldFocused: Bool

  private var theme: WritingTheme { themes.theme }
  private var isRescheduling: Bool {
    if case .reschedule = store.sendLaterPicker { return true }
    return false
  }

  private var parsedDate: Date? { SendLaterTime.parse(query) }
  private var suggestions: [SendLaterTime.Suggestion] { SendLaterTime.suggestions() }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "clock")
          .font(.system(size: 12, weight: .semibold))
        Text(isRescheduling ? "Reprogrammer" : "Envoyer plus tard")
          .font(Typography.sidebarItem(themes.typeface))
      }
      .foregroundStyle(theme.ink)

      TextField("Quand ? (« demain 9h », « lundi matin », « dans 2h »)", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(Typography.composer(themes.typeface))
        .focused($isFieldFocused)
        .onSubmit(confirm)

      if query.trimmingCharacters(in: .whitespaces).isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(suggestions) { suggestion in
            suggestionRow(suggestion.title, suggestion.date)
          }
        }
      } else if let parsedDate {
        Text(SendLaterTime.label(for: parsedDate))
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.accent)
      } else {
        Text("Je ne comprends pas cette date.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkTertiary)
      }

      Toggle("Seulement s’il n’a pas répondu d’ici là", isOn: $onlyIfNoReply)
        .toggleStyle(.checkbox)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)

      Text("Part seulement si Correspondance tourne, Mac éveillé.")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)

      HStack {
        Spacer()
        Button("Annuler") { store.sendLaterPicker = nil }
          .keyboardShortcut(.cancelAction)
        Button(isRescheduling ? "Reprogrammer" : "Choisir", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(parsedDate == nil)
      }
    }
    .padding(Spacing.md)
    .frame(width: 320)
    .onAppear {
      if case .reschedule(let id) = store.sendLaterPicker,
         let existing = store.scheduledMessages.first(where: { $0.id == id })
      {
        onlyIfNoReply = existing.onlyIfNoReply
      } else if let config = store.sendLaterConfig {
        onlyIfNoReply = config.onlyIfNoReply
      }
      isFieldFocused = true
    }
  }

  private func suggestionRow(_ title: String, _ date: Date) -> some View {
    Button {
      store.applySendLater(SendLaterConfig(sendAt: date, onlyIfNoReply: onlyIfNoReply))
    } label: {
      HStack {
        Text(title)
          .font(Typography.sidebarItem(themes.typeface))
          .foregroundStyle(theme.ink)
        Spacer()
        Text(SendLaterTime.label(for: date))
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(SendLaterRowStyle(theme: theme))
  }

  private func confirm() {
    guard let parsedDate else { return }
    store.applySendLater(SendLaterConfig(sendAt: parsedDate, onlyIfNoReply: onlyIfNoReply))
  }
}

private struct SendLaterRowStyle: ButtonStyle {
  let theme: WritingTheme
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hovered || configuration.isPressed ? theme.selection : .clear)
      )
      .onHover { hovered = $0 }
  }
}

/// Bandeau posé au-dessus du composer tant que le « plus tard » est actif :
/// l'heure choisie (cliquer pour changer) et sa croix.
struct SendLaterBanner: View {
  @Environment(InboxStore.self) private var store
  let config: SendLaterConfig
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 8) {
      Button { store.toggleSendLaterPicker() } label: {
        HStack(spacing: 5) {
          Image(systemName: "clock")
            .font(.system(size: 10, weight: .semibold))
          Text("Partira \(SendLaterTime.label(for: config.sendAt))")
            .font(Typography.meta(typeface))
          if config.onlyIfNoReply {
            Text("· si pas de réponse")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkSecondary)
          }
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(theme.accent)
      }
      .buttonStyle(.plain)
      .help("Changer l’heure d’envoi (⌘⇧L)")
      .accessibilityLabel("Reprogrammer l’envoi")

      Text("Entrée programme au lieu d’envoyer")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .lineLimit(1)

      Spacer(minLength: 8)
      Button { store.cancelSendLater() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Annuler l’envoi différé")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
    .background(theme.paperSecondary)
  }
}

/// Un message programmé, en bas du fil : une bulle en pointillé, à droite,
/// avec son heure de départ. Clic droit : maintenant / reprogrammer / supprimer.
struct ScheduledMessageRow: View {
  @Environment(InboxStore.self) private var store
  let message: ScheduledMessage
  let theme: WritingTheme
  let typeface: WritingTypeface
  /// Prose du Focus : pas de bulle, un paragraphe atténué.
  var isProse = false

  private var statusLine: String {
    if let error = message.lastError { return "Non envoyé : \(error)" }
    var line = "Partira \(SendLaterTime.label(for: message.sendAt))"
    if message.onlyIfNoReply { line += " · si pas de réponse" }
    return line
  }

  var body: some View {
    Group {
      if isProse {
        VStack(alignment: .leading, spacing: 4) {
          status
          Text(message.displayText)
            .foregroundStyle(theme.ink.opacity(0.55))
        }
      } else {
        HStack {
          Spacer(minLength: 48)
          VStack(alignment: .trailing, spacing: 3) {
            Text(message.displayText)
              .font(Typography.bubble(typeface))
              .foregroundStyle(theme.ink.opacity(0.75))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                  .foregroundStyle(message.lastError == nil ? theme.accent.opacity(0.6) : Color.red.opacity(0.6))
              )
            status
          }
        }
      }
    }
    .contentShape(Rectangle())
    .contextMenu { ScheduledMessageMenu(message: message) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Message programmé, \(statusLine) : \(message.displayText)")
  }

  private var status: some View {
    HStack(spacing: 4) {
      Image(systemName: message.lastError == nil ? "clock" : "exclamationmark.triangle")
        .font(.system(size: 9, weight: .semibold))
      Text(statusLine)
        .font(Typography.meta(typeface))
        .lineLimit(2)
    }
    .foregroundStyle(message.lastError == nil ? theme.inkTertiary : Color.red.opacity(0.85))
  }
}

/// Menu commun au fil et à la liste « Programmés ».
struct ScheduledMessageMenu: View {
  @Environment(InboxStore.self) private var store
  let message: ScheduledMessage

  var body: some View {
    Button(message.lastError == nil ? "Envoyer maintenant" : "Réessayer maintenant") {
      Task { await store.sendScheduledNow(message.id) }
    }
    Button("Reprogrammer…") {
      Task {
        if store.selectedConversationID != message.conversationID {
          await store.select(message.conversationID)
        }
        store.presentReschedule(message.id)
      }
    }
    Divider()
    Button("Supprimer sans envoyer", role: .destructive) {
      store.unschedule(message.id)
    }
  }
}

/// Ligne de la vue « Programmés » : le fil, et son prochain départ.
struct ScheduledConversationRow: View {
  let conversation: Conversation
  let scheduled: [ScheduledMessage]
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  private var next: ScheduledMessage? { scheduled.first }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ConversationAvatarView(conversation: conversation, size: 36, theme: theme)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(conversation.title)
            .font(Typography.sidebarItem(typeface))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 6)
          if let next {
            HStack(spacing: 3) {
              Image(systemName: next.lastError == nil ? "clock" : "exclamationmark.triangle")
                .font(.system(size: 8, weight: .semibold))
              Text(SendLaterTime.label(for: next.sendAt))
            }
            .font(Typography.meta(typeface))
            .foregroundStyle(next.lastError == nil ? theme.accent : Color.red.opacity(0.85))
            .lineLimit(1)
            .layoutPriority(1)
          }
        }
        Text(next?.displayText ?? "")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if scheduled.count > 1 {
          Text("+ \(scheduled.count - 1) autre\(scheduled.count > 2 ? "s" : "")")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
