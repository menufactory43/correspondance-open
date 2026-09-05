import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// « Quand ? » — les raccourcis du Mac, et une date libre.
///
/// Les raccourcis viennent de `SendLaterTime` : ceux déjà passés ne sont pas
/// proposés (« Ce soir » n'a pas de sens à 22 h). En dessous, un sélecteur de
/// date, pour tout le reste.
///
/// Et une ligne discrète, dite une fois, en bas : l'envoi part **quand l'app
/// est ouverte** à l'heure dite. iOS ne garantit rien en arrière-plan pour ça,
/// et laisser croire le contraire serait la seule vraie faute de cet écran.
struct SendLaterSheet: View {
  let conversationID: String
  /// `nil` = programmer le brouillon ; sinon, déplacer un message déjà programmé.
  var rescheduling: String?

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var customDate = Date().addingTimeInterval(3_600)
  @State private var onlyIfNoReply = false

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  /// Il y a quelque chose à programmer : un brouillon, une pièce jointe, ou
  /// un message déjà programmé qu'on déplace.
  private var hasSomethingToSend: Bool {
    rescheduling != nil || store.canSend(conversationID)
  }

  var body: some View {
    NavigationStack {
      List {
        if !hasSomethingToSend {
          Section {
            Label("Écris d'abord le message, ou joins une photo : c'est lui qui partira plus tard.", systemImage: "pencil.line")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkSecondary)
          }
        }
        Section {
          ForEach(SendLaterTime.suggestions()) { suggestion in
            Button {
              choose(suggestion.date)
            } label: {
              HStack {
                Text(suggestion.title).foregroundStyle(theme.ink)
                Spacer()
                Text(SendLaterTime.timeString(suggestion.date))
                  .font(Typography.meta(typeface))
                  .monospacedDigit()
                  .foregroundStyle(theme.inkTertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasSomethingToSend)
          }
        } header: {
          Text("Quand ?")
        }

        Section {
          DatePicker(
            "Date et heure",
            selection: $customDate,
            in: Date()...,
            displayedComponents: [.date, .hourAndMinute]
          )
          .datePickerStyle(.compact)
          Button {
            choose(customDate)
          } label: {
            Label(
              "Programmer pour \(SendLaterTime.label(for: customDate))",
              systemImage: "clock.badge.checkmark"
            )
          }
          .disabled(customDate <= Date() || !hasSomethingToSend)
        }

        if rescheduling == nil {
          Section {
            Toggle("Seulement s'il n'a pas répondu", isOn: $onlyIfNoReply)
          } footer: {
            Text("Le message s'efface tout seul si un message arrive d'ici là.")
              .font(Typography.meta(typeface))
          }
        }

        Section {
          EmptyView()
        } footer: {
          Label(
            "Part quand l'app est ouverte à l'heure dite — iOS ne réveille rien pour ça.",
            systemImage: "info.circle"
          )
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle(rescheduling == nil ? "Envoyer plus tard" : "Déplacer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .presentationDetents([.medium, .large])
  }

  private func choose(_ date: Date) {
    if let rescheduling {
      store.reschedule(rescheduling, at: date)
    } else {
      Task { await store.scheduleDraft(conversationID: conversationID, at: date, onlyIfNoReply: onlyIfNoReply) }
    }
    dismiss()
  }
}

/// Les messages qui attendent leur heure.
///
/// Accessible depuis le menu du titre de l'inbox, comme Beeper — un endroit,
/// pas dix. Chaque ligne dit son fil, son heure, et ce qu'elle porte ;
/// « Modifier » la ramène dans le composer, où on la corrige en la réécrivant.
struct ScheduledMessagesView: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var rescheduling: ScheduledMessage?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    NavigationStack {
      Group {
        if store.scheduled.isEmpty {
          empty
        } else {
          list
        }
      }
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Programmés")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .sheet(item: $rescheduling) { message in
      SendLaterSheet(conversationID: message.conversationID, rescheduling: message.id)
        .environment(store)
        .environment(themes)
    }
  }

  private var list: some View {
    List {
      ForEach(store.scheduled) { message in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 5) {
            Image(systemName: "clock")
              .font(.system(size: 10))
            Text(SendLaterTime.label(for: message.sendAt))
              .fontWeight(.semibold)
            if message.onlyIfNoReply {
              Text("· sauf réponse")
            }
            Spacer(minLength: 6)
            Text(store.conversation(message.conversationID)?.title ?? "Fil inconnu")
              .lineLimit(1)
          }
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)

          Text(message.displayText)
            .font(Typography.body(typeface, size: 15))
            .foregroundStyle(theme.ink)
            .lineLimit(3)

          if let error = message.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.accent)
          }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            store.cancelScheduled(message.id)
          } label: {
            Label("Annuler", systemImage: "trash")
          }
        }
        .contextMenu {
          Button {
            rescheduling = message
          } label: {
            Label("Déplacer…", systemImage: "clock.arrow.circlepath")
          }
          Button {
            store.editScheduled(message.id)
            dismiss()
          } label: {
            Label("Modifier", systemImage: "pencil")
          }
          Button(role: .destructive) {
            store.cancelScheduled(message.id)
          } label: {
            Label("Annuler l'envoi", systemImage: "trash")
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .safeAreaInset(edge: .bottom) {
      Text("Ces messages partent quand l'app est ouverte à l'heure dite.")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }
  }

  private var empty: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "clock")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(theme.inkTertiary)
      Text("Rien de programmé")
        .font(Typography.emptyState(typeface))
        .foregroundStyle(theme.inkSecondary)
      Text("Le **+** du composer, « Envoyer plus tard ».")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
