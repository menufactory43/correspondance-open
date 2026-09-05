import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La fiche d'une personne, poussée depuis la liste des membres d'un groupe :
/// sa photo, son nom, son numéro, de quoi lui écrire en privé, et les groupes
/// où l'on se croise. Tout vient de la base locale — aucun appel au Relais.
struct MemberProfileView: View {
  let member: RelayStore.ThreadMember
  /// Le fil d'où l'on vient : il donne le réseau, et ne compte pas parmi les
  /// groupes en commun.
  let fromConversationID: String
  /// Ouvrir un fil depuis la fiche : c'est la feuille qui nous porte qui sait
  /// se refermer, puis changer la sélection.
  let openConversation: (String) -> Void

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var profile: RelayStore.MemberProfile?
  @State private var isStarting = false
  @State private var failure: String?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.lg) {
        header
        actions
        sharedGroups
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .containerRelativeFrame(.horizontal)
    }
    .background(theme.paper.ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(theme.paper, for: .navigationBar)
    .task(id: member.id) {
      profile = await store.profile(of: member, from: fromConversationID)
    }
    .alert("Fil pas encore ouvert", isPresented: Binding(
      get: { failure != nil },
      set: { if !$0 { failure = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(failure ?? "")
    }
  }

  // MARK: - En-tête

  private var header: some View {
    VStack(spacing: Spacing.xs) {
      MemberAvatar(conversationID: fromConversationID, userID: member.userID, name: member.name, size: 88, theme: theme)
      Text(member.name)
        .font(Typography.body(typeface, size: 22))
        .fontWeight(.semibold)
        .foregroundStyle(theme.ink)
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.sm)
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    guard let profile else { return "" }
    if let phone = profile.phone { return "\(profile.network.labelFR) · \(phone)" }
    return profile.network.labelFR
  }

  // MARK: - Écrire, copier

  private var actions: some View {
    HStack(spacing: Spacing.sm) {
      Button {
        write()
      } label: {
        actionLabel(
          isStarting ? "Ouverture…" : (profile?.directConversation == nil ? "Écrire" : "Ouvrir le fil"),
          systemImage: "square.and.pencil"
        )
      }
      .buttonStyle(.plain)
      .disabled(isStarting || profile == nil)
      if let phone = profile?.phone {
        Button {
          Platform.copyToPasteboard(phone)
        } label: {
          actionLabel("Copier le numéro", systemImage: "doc.on.doc")
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func actionLabel(_ title: String, systemImage: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(theme.accent)
      Text(title)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary))
    .contentShape(Rectangle())
    .opacity(isStarting ? 0.5 : 1)
  }

  /// Le tête-à-tête existe : on l'ouvre. Sinon le pont le crée à partir du
  /// numéro ; le salon arrive par le `/sync` qui suit.
  private func write() {
    guard let profile else { return }
    if let direct = profile.directConversation {
      openConversation(store.displayRowID(for: direct.id))
      return
    }
    isStarting = true
    Task {
      do {
        if let id = try await store.startDirectChat(with: member, network: profile.network, phone: profile.phone) {
          openConversation(store.displayRowID(for: id))
        } else {
          failure = "Le pont n'a pas encore ouvert le fil. Il apparaîtra dans l'inbox dès qu'il l'aura fait."
        }
      } catch {
        failure = RelayStore.readable(error)
      }
      isStarting = false
    }
  }

  // MARK: - Groupes en commun

  @ViewBuilder
  private var sharedGroups: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Groupes en commun")
        .font(Typography.meta(typeface))
        .fontWeight(.semibold)
        .foregroundStyle(theme.inkSecondary)
        .padding(.horizontal, 4)
      if let profile {
        if profile.sharedGroups.isEmpty {
          Text("Aucun autre groupe \(profile.network.labelFR) en commun.")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(profile.sharedGroups.enumerated()), id: \.element.id) { index, group in
              Button {
                openConversation(group.id)
              } label: {
                HStack(spacing: 12) {
                  ConversationAvatar(conversation: group, size: 40, theme: theme, showsNetworkBadge: false)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                      .font(Typography.body(typeface, size: 16))
                      .foregroundStyle(theme.ink)
                      .lineLimit(1)
                    Text(group.preview)
                      .font(Typography.meta(typeface))
                      .foregroundStyle(theme.inkTertiary)
                      .lineLimit(1)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              if index < profile.sharedGroups.count - 1 {
                Divider().overlay(theme.edge.opacity(0.6)).padding(.leading, 64)
              }
            }
          }
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary))
        }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.md)
      }
    }
  }
}
