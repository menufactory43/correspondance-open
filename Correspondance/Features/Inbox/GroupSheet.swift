import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// La fiche d'un groupe sur Mac : son nom, ses membres, et les deux gestes qui
/// s'y jouent — ajouter, retirer.
///
/// Chaque geste est absent là où le pont ne le relaie pas : renommer un groupe
/// Instagram ne changerait le nom que chez nous, retirer quelqu'un ne le
/// sortirait de rien. On préfère un champ qui n'est pas là à un bouton qui ment.
struct GroupSheet: View {
  let conversationID: String

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var members: [InboxStore.GroupMember] = []
  @State private var name = ""
  @State private var invitee = ""
  @State private var pendingRemoval: InboxStore.GroupMember?

  private var theme: WritingTheme { themes.theme }
  private var conversation: Conversation? { store.conversationRow(conversationID) }
  private var network: MessageNetwork { conversation?.network ?? .whatsapp }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      header
      if network.supportsGroupRename { renameField }
      membersList
      if network.supportsMemberInvite { inviteField }
      HStack {
        Spacer()
        Button("Terminer") { close() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Spacing.md)
    .frame(width: 380, height: 460)
    .background(theme.paper)
    .task { members = await store.members(of: conversationID) }
    .confirmationDialog(
      pendingRemoval.map { "Retirer \($0.name) du groupe ?" } ?? "",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { member in
      Button("Retirer", role: .destructive) { remove(member) }
      Button("Annuler", role: .cancel) { pendingRemoval = nil }
    } message: { _ in
      Text("Le retrait part sur \(network.labelFR) : la personne ne recevra plus les messages du groupe.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(conversation?.title ?? "Groupe")
        .font(Typography.body(themes.typeface, size: 15).weight(.semibold))
        .foregroundStyle(theme.ink)
      Text("\(network.labelFR) · \(members.count) membres")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)
    }
  }

  private var renameField: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Nom du groupe")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      HStack(spacing: 6) {
        TextField(conversation?.title ?? "Nom", text: $name)
          .textFieldStyle(.roundedBorder)
          .onSubmit { rename() }
        Button("Renommer", action: rename)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var membersList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Membres")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      List(members) { member in
        HStack(spacing: 6) {
          Text(member.name)
            .font(Typography.body(themes.typeface, size: 13))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          Spacer(minLength: 4)
          if network.supportsMemberRemoval {
            Button("Retirer…") { pendingRemoval = member }
              .buttonStyle(.borderless)
              .font(Typography.meta(themes.typeface))
          }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .frame(maxHeight: .infinity)
    }
  }

  private var inviteField: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Ajouter quelqu’un")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      HStack(spacing: 6) {
        TextField(store.invitePromptFR(for: network), text: $invitee)
          .textFieldStyle(.roundedBorder)
          .onSubmit { invite() }
        Button("Ajouter", action: invite)
          .disabled(invitee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func rename() {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    name = ""
    Task { await store.renameGroup(conversationID: conversationID, name: value) }
  }

  private func invite() {
    let value = invitee.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    invitee = ""
    Task {
      await store.inviteMember(value, conversationID: conversationID)
      members = await store.members(of: conversationID)
    }
  }

  private func remove(_ member: InboxStore.GroupMember) {
    pendingRemoval = nil
    Task {
      await store.removeMember(conversationID: conversationID, userID: member.userID)
      members = await store.members(of: conversationID)
    }
  }

  private func close() {
    store.dismissGroupSheet()
    dismiss()
  }
}
