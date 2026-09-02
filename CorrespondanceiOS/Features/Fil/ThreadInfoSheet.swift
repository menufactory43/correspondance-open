import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La fiche d'un fil, ouverte depuis la pilule de l'en-tête.
///
/// La photo et le nom, trois gestes (chercher, archiver, plus), les médias du
/// fil en quatre carrés avec « Voir plus », puis les membres et de quoi en
/// ajouter un. Tout vient de ce qui est déjà sur l'appareil : les médias sont
/// ceux du cache, les membres ceux du salon.
struct ThreadInfoSheet: View {
  let conversationID: String

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var isSearching = false
  @State private var isAddingMember = false
  @State private var newMember = ""
  @State private var inviteError: String?
  @State private var inviteSent = false
  @State private var isRenaming = false
  @State private var newName = ""
  /// Le membre qu'on s'apprête à retirer : la question se pose une fois.
  @State private var pendingRemoval: RelayStore.ThreadMember?
  @State private var members: [RelayStore.ThreadMember] = []
  /// Vrai quand le fil peut accueillir « cc » — pas encore membre.
  @State private var agentInvitable = false
  /// Le média que la visionneuse montre, tapé dans les quatre carrés.
  @State private var openedMedia: OpenedMedia?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }
  private var conversation: Conversation? { store.conversation(conversationID) }
  private var media: [MessageAttachment] { store.media(conversationID) }

  /// Ajouter quelqu'un passe par le ghost de son numéro ou de son pseudo.
  /// La table des capacités tranche — plus aucune liste de réseaux en dur.
  private var canAddMember: Bool { store.canInviteMember(conversationID) }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let conversation {
          VStack(spacing: Spacing.lg) {
            header(conversation)
            confidentialite(conversation)
            actionRow(conversation)
            mediaSection
            membersSection(conversation)
          }
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
        }
      }
      .background(theme.paper.ignoresSafeArea())
      .fullScreenCover(item: $openedMedia) { start in
        MediaViewer(media: media, startAt: start.id)
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
      .navigationDestination(for: MediaGridRoute.self) { _ in
        ThreadMediaGrid(conversationID: conversationID)
      }
    }
    .tint(theme.accent)
    .task(id: conversationID) {
      members = await store.members(conversationID)
      agentInvitable = await store.agentInvitable(conversationID)
    }
    .sheet(isPresented: $isSearching) {
      SearchSheet(scope: conversationID)
        .environment(store)
        .environment(themes)
    }
    .alert("Ajouter un membre", isPresented: $isAddingMember) {
      TextField(addMemberPrompt, text: $newMember)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Ajouter") { invite() }
      Button("Annuler", role: .cancel) { newMember = "" }
    } message: {
      Text(conversation?.network == .instagram || conversation?.network == .messenger
        ? "Son pseudo, ou son identifiant."
        : "Son numéro, avec l'indicatif du pays.")
    }
    .alert("Renommer le groupe", isPresented: $isRenaming) {
      TextField("Nom du groupe", text: $newName)
      Button("Renommer") { rename() }
      Button("Annuler", role: .cancel) { newName = "" }
    } message: {
      Text("Le nouveau nom part sur \(conversation?.network.labelFR ?? "le réseau") : tout le groupe le verra.")
    }
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
      Text("Le retrait part sur le réseau : cette personne ne recevra plus les messages du groupe.")
    }
    .alert("Impossible d'ajouter ce membre", isPresented: Binding(
      get: { inviteError != nil },
      set: { if !$0 { inviteError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(inviteError ?? "")
    }
  }

  // MARK: - En-tête

  private func header(_ conversation: Conversation) -> some View {
    VStack(spacing: Spacing.xs) {
      ConversationAvatar(conversation: conversation, size: 88, theme: theme)
      Text(conversation.title)
        .font(Typography.body(typeface, size: 22))
        .fontWeight(.semibold)
        .foregroundStyle(theme.ink)
        .multilineTextAlignment(.center)
      Text(subtitle(conversation))
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.sm)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Le chiffrement, dit en une ligne et une phrase

  /// Trois états, jamais quatre, et **jamais le cadenas plein sur un portail** :
  /// le pont déchiffre pour traduire, c'est sa fonction. Le texte vient de
  /// `ConfidentialiteAffichee`, dans le noyau, pour que le Mac et l'iPhone
  /// disent le même mot.
  private func confidentialite(_ conversation: Conversation) -> some View {
    let etat = conversation.confidentialite
    return HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: etat.symbole)
        .foregroundStyle(theme.inkSecondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(etat.libelleFR)
          .font(Typography.body(typeface, size: 14))
          .foregroundStyle(theme.ink)
        Text(etat.phraseFR)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }

  private func subtitle(_ conversation: Conversation) -> String {
    guard conversation.isGroup else { return conversation.network.labelFR }
    let count = members.count
    if count == 0 { return "\(conversation.network.labelFR) · groupe" }
    return "\(conversation.network.labelFR) · \(count) membre\(count > 1 ? "s" : "")"
  }

  // MARK: - Les trois gestes

  private func actionRow(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.sm) {
      actionButton("Rechercher", systemImage: "magnifyingglass") { isSearching = true }
      actionButton(
        store.isArchived(conversationID) ? "Désarchiver" : "Archiver",
        systemImage: store.isArchived(conversationID) ? "tray.and.arrow.up" : "archivebox"
      ) {
        store.toggleArchived(conversationID)
      }
      Menu {
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
        if store.canRenameGroup(conversationID) {
          Button {
            newName = conversation.title
            isRenaming = true
          } label: {
            Label("Renommer le groupe…", systemImage: "pencil")
          }
        }
        if !conversation.isGroup, !conversation.address.isEmpty {
          Button {
            Platform.copyToPasteboard(conversation.address)
          } label: {
            Label("Copier l'adresse", systemImage: "doc.on.doc")
          }
        }
      } label: {
        actionLabel("Plus", systemImage: "ellipsis")
      }
      .accessibilityLabel("Plus d'actions")
    }
  }

  private func actionButton(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      actionLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.plain)
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
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary)
    )
    .contentShape(Rectangle())
  }

  // MARK: - Les médias

  private var mediaSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Médias")
      if media.isEmpty {
        Text("Aucune photo ni vidéo dans ce fil pour l'instant.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 6)
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
          ForEach(Array(media.prefix(4).enumerated()), id: \.element.id) { rank, attachment in
            MediaTile(attachment: attachment, cornerRadius: 14, theme: theme) {
              openedMedia = OpenedMedia(rank)
            }
          }
        }
        NavigationLink(value: MediaGridRoute()) {
          HStack {
            Text("Voir plus")
              .font(Typography.body(typeface, size: 15))
              .foregroundStyle(theme.accent)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.paperSecondary)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text(mediaLabel)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .padding(.horizontal, 4)
      }
    }
  }

  private var mediaLabel: String {
    let photos = media.filter(\.isImage).count
    let videos = media.count - photos
    var parts: [String] = []
    if photos > 0 { parts.append("\(photos) photo\(photos > 1 ? "s" : "")") }
    if videos > 0 { parts.append("\(videos) vidéo\(videos > 1 ? "s" : "")") }
    return parts.joined(separator: " et ")
  }

  // MARK: - Les membres

  private func membersSection(_ conversation: Conversation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle(conversation.isGroup ? "Membres" : "Contact")
      VStack(spacing: 0) {
        if canAddMember {
          Button {
            newMember = ""
            isAddingMember = true
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "person.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.accent.opacity(0.12)))
              Text("Ajouter un membre")
                .font(Typography.body(typeface, size: 16))
                .foregroundStyle(theme.accent)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if !members.isEmpty { rowDivider }
        }
        if agentInvitable {
          Button {
            agentInvitable = false
            let fil = conversationID
            Task { @MainActor in
              do {
                try await store.inviteAgent(fil)
              } catch {
                inviteError = RelayStore.readable(error)
                agentInvitable = true
              }
            }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "pencil.line")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.accent.opacity(0.12)))
              VStack(alignment: .leading, spacing: 1) {
                Text("Inviter cc")
                  .font(Typography.body(typeface, size: 16))
                  .foregroundStyle(theme.accent)
                Text("L'agent pourra proposer des réponses ici")
                  .font(Typography.meta(typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if !members.isEmpty { rowDivider }
        }
        if members.isEmpty, !conversation.isGroup {
          memberRow(name: conversation.title, detail: conversation.address, avatarUserID: nil)
        }
        ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
          memberRow(name: member.name, detail: nil, avatarUserID: member.userID)
            .contextMenu {
              if store.canRemoveMember(conversationID) {
                Button(role: .destructive) {
                  pendingRemoval = member
                } label: {
                  Label("Retirer du groupe…", systemImage: "person.badge.minus")
                }
              }
            }
          if index < members.count - 1 { rowDivider }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary)
      )
      if inviteSent {
        Text("Invitation envoyée — le groupe s'en souviendra au prochain passage du pont.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .padding(.horizontal, 4)
      }
    }
  }

  private func memberRow(name: String, detail: String?, avatarUserID: String?) -> some View {
    HStack(spacing: 12) {
      MemberAvatar(conversationID: conversationID, userID: avatarUserID, name: name, size: 40, theme: theme)
      VStack(alignment: .leading, spacing: 1) {
        Text(name)
          .font(Typography.body(typeface, size: 16))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  private var rowDivider: some View {
    Divider().overlay(theme.edge.opacity(0.6)).padding(.leading, 64)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(Typography.meta(typeface))
      .fontWeight(.semibold)
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, 4)
  }

  private var addMemberPrompt: String {
    switch conversation?.network {
    case .instagram, .messenger: "pseudo"
    case .signal: "identifiant Signal"
    default: "+33 6 12 34 56 78"
    }
  }

  private func rename() {
    let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    newName = ""
    guard !value.isEmpty else { return }
    let fil = conversationID
    Task { @MainActor in
      do {
        try await store.renameGroup(value, conversationID: fil)
      } catch {
        inviteError = RelayStore.readable(error)
      }
    }
  }

  private func remove(_ member: RelayStore.ThreadMember) {
    pendingRemoval = nil
    let fil = conversationID
    Task { @MainActor in
      do {
        try await store.removeMember(member.userID, conversationID: fil)
        members = await store.members(fil)
      } catch {
        inviteError = RelayStore.readable(error)
      }
    }
  }

  private func invite() {
    let identifier = newMember.trimmingCharacters(in: .whitespacesAndNewlines)
    newMember = ""
    guard !identifier.isEmpty else { return }
    let fil = conversationID
    Task { @MainActor in
      do {
        try await store.inviteMember(identifier, conversationID: fil)
        inviteSent = true
        members = await store.members(fil)
      } catch {
        inviteError = RelayStore.readable(error)
      }
    }
  }
}

/// La destination « Voir plus » : une valeur sans état, pour un seul écran.
private struct MediaGridRoute: Hashable {}

/// Tous les médias du fil, trois par ligne, du plus récent au plus ancien.
struct ThreadMediaGrid: View {
  let conversationID: String

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var opened: OpenedMedia?

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    let media = store.media(conversationID)
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
        ForEach(Array(media.enumerated()), id: \.element.id) { rank, attachment in
          MediaTile(attachment: attachment, cornerRadius: 4, theme: theme) {
            opened = OpenedMedia(rank)
          }
        }
      }
      .padding(.horizontal, 3)
    }
    .fullScreenCover(item: $opened) { start in
      MediaViewer(media: media, startAt: start.id)
    }
    .background(theme.paper.ignoresSafeArea())
    .navigationTitle("Médias")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(theme.paper, for: .navigationBar)
  }
}

/// Un carré de la fiche : la même tuile que celle des mosaïques du fil, cadrée
/// au remplissage, et qui ouvre la visionneuse sur tous les médias du fil.
struct MediaTile: View {
  let attachment: MessageAttachment
  var cornerRadius: CGFloat
  let theme: WritingTheme
  var onOpen: (() -> Void)?

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        MediaTileImage(
          url: attachment.resolvedFileURL,
          isVideo: attachment.isVideo,
          placeholder: theme.bubbleIn,
          accentInk: theme.inkTertiary
        )
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(theme.edge.opacity(0.4), lineWidth: 0.5)
      )
      .contentShape(Rectangle())
      .onTapGesture { onOpen?() }
      .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
      .accessibilityLabel(attachment.filename ?? (attachment.isVideo ? "Vidéo" : "Photo"))
  }
}

/// La photo d'un membre du groupe — celle de son ghost — ou ses initiales.
struct MemberAvatar: View {
  let conversationID: String
  var userID: String?
  let name: String
  var size: CGFloat = 40
  let theme: WritingTheme

  @Environment(RelayStore.self) private var store
  @State private var image: PlatformImage?

  private var initials: String {
    let parts = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { !$0.isEmpty }
    if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "?" : String(trimmed.prefix(2)).uppercased()
  }

  var body: some View {
    ZStack {
      if let image {
        Image(platformImage: image).resizable().scaledToFill()
      } else {
        Circle().fill(SenderTint.color(for: name, theme: theme))
        Text(initials)
          .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.95))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .task(id: userID) {
      guard let userID else { return }
      guard let data = await store.matrix.memberAvatarData(conversationID: conversationID, userID: userID)
      else { return }
      image = PlatformImage(data: data)
    }
    .accessibilityHidden(true)
  }
}
