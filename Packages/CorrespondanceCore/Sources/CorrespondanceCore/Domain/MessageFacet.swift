import Foundation

/// Les onglets de la recherche : Images · Vidéos · Liens · Fichiers · Brouillons.
///
/// Ce ne sont pas des filtres de conversation (ceux-là sont dans
/// `InboxFiltering`) mais des façons de regarder le contenu déjà chargé. Cinq
/// questions qu'on se pose vraiment : « la photo qu'elle m'a envoyée », « le
/// lien de l'article », « le PDF du devis », « ce que j'ai commencé à écrire ».
///
/// Purs et testables : la recherche par médias de la décision 10 commence ici,
/// et elle vaudra pour les deux plateformes.
public enum MessageFacet: String, CaseIterable, Identifiable, Sendable {
  case images
  case videos
  case links
  case files
  case drafts

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .images: "Images"
    case .videos: "Vidéos"
    case .links: "Liens"
    case .files: "Fichiers"
    case .drafts: "Brouillons"
    }
  }

  public var systemImage: String {
    switch self {
    case .images: "photo"
    case .videos: "video"
    case .links: "link"
    case .files: "paperclip"
    case .drafts: "pencil.line"
    }
  }

  /// Un brouillon n'est pas un message : il n'existe que dans l'état de
  /// conversation. L'onglet existe quand même — c'est la même question posée
  /// au même endroit — mais il se répond ailleurs.
  public var isConversationFacet: Bool { self == .drafts }
}

/// Le tri par type, sans état ni effet de bord.
public enum FacetedSearch {
  /// Ce message entre-t-il dans cet onglet ?
  ///
  /// « Fichiers » attrape tout ce qui n'est ni image ni vidéo — un vocal, un
  /// PDF, un `.zip`. Rien ne doit tomber entre deux onglets : une pièce jointe
  /// qu'on ne sait pas nommer reste un fichier.
  public static func matches(_ message: ChatMessage, facet: MessageFacet) -> Bool {
    switch facet {
    case .images:
      return message.attachments.contains(where: \.isImage)
    case .videos:
      return message.attachments.contains(where: \.isVideo)
    case .files:
      return message.attachments.contains { !$0.isImage && !$0.isVideo }
    case .links:
      return TextLinks.firstWebURL(in: message.text) != nil
    case .drafts:
      // Un brouillon n'est pas dans le fil : voir `conversationsWithDrafts`.
      return false
    }
  }

  /// Les messages d'un onglet, du plus récent au plus ancien — on cherche
  /// presque toujours quelque chose de récent.
  ///
  /// `query` reste optionnelle : un onglet seul est déjà une recherche.
  public static func messages(
    _ messages: [ChatMessage],
    facet: MessageFacet,
    query: String = ""
  ) -> [ChatMessage] {
    let needle = ConversationSearch.fold(query)
    return messages
      .filter { matches($0, facet: facet) }
      .filter { message in
        guard !needle.isEmpty else { return true }
        let haystack = ConversationSearch.fold(
          [message.text, message.senderName ?? "",
           message.attachments.compactMap(\.filename).joined(separator: " ")]
            .joined(separator: " ")
        )
        return haystack.contains(needle)
      }
      .sorted { $0.sentAt > $1.sentAt }
  }

  /// Les conversations qui portent un brouillon non vide, les plus récentes
  /// d'abord. `drafts` vient de l'état de conversation du Relais, corrigé par
  /// ce qu'on est en train de taper.
  public static func conversationsWithDrafts(
    _ conversations: [Conversation],
    drafts: [String: String],
    query: String = ""
  ) -> [Conversation] {
    let needle = ConversationSearch.fold(query)
    return conversations
      .filter { conversation in
        let draft = drafts[conversation.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !draft.isEmpty else { return false }
        guard !needle.isEmpty else { return true }
        return ConversationSearch.fold("\(conversation.title) \(draft)").contains(needle)
      }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }
}
