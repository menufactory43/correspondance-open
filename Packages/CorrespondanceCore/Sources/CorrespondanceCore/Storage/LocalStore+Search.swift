import Foundation

/// La recherche des fils du Relais, posée sur FTS5 plutôt que sur ce qui se
/// trouve en mémoire.
///
/// Avant, chercher dans les fils bridgés voulait dire les avoir tous chargés :
/// on ne trouvait que ce qu'on avait déjà ouvert. La base, elle, a tout, et
/// l'index plein texte répond sans relire les messages un par un.
///
/// iMessage garde son chemin d'origine (`chat.db`) — sa base n'est pas la
/// nôtre, et rien ne justifie d'en recopier deux millions de lignes ici.
public extension LocalStore {
  /// Un message trouvé, et le salon d'où il vient : un message seul ne dit rien.
  struct SearchHit: Sendable {
    public var roomID: String
    public var conversationID: String
    public var message: ChatMessage
  }

  /// Les messages qui répondent à la question, du plus récent au plus ancien.
  ///
  /// - Parameter facet: l'onglet, quand il y en a un. Il filtre sur les
  ///   colonnes indexées ; l'exactitude est ensuite refaite en Swift par
  ///   `FacetedSearch.matches`, qui reste la seule définition d'un onglet.
  func search(
    query: String,
    facet: MessageFacet? = nil,
    roomIDs: Set<String>? = nil,
    limit: Int = 500
  ) -> [SearchHit] {
    guard facet != nil || !Self.ftsQuery(query).isEmpty else { return [] }
    guard facet?.isConversationFacet != true else { return [] }
    let match = Self.ftsQuery(query)

    return read([]) {
      var conditions: [String] = []
      var bindings: [SQLiteValue] = []
      var from = "messages"
      if !match.isEmpty {
        from = "messages JOIN messages_fts ON messages_fts.rowid = messages.rowid"
        conditions.append("messages_fts MATCH ?")
        bindings.append(.text(match))
      }
      if let facet, let predicate = Self.predicate(for: facet) {
        conditions.append(predicate)
      }
      if let roomIDs, !roomIDs.isEmpty {
        let holes = Array(repeating: "?", count: roomIDs.count).joined(separator: ", ")
        conditions.append("messages.room_id IN (\(holes))")
        bindings.append(contentsOf: roomIDs.sorted().map { .text($0) })
      }
      let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
      let sql = """
      SELECT messages.event_id, messages.room_id, messages.conversation_id, messages.sent_at,
             messages.sender_id, messages.sender_name, messages.text, messages.is_from_me,
             messages.attachment_names, messages.attachment_types, messages.payload
      FROM \(from) \(whereClause)
      ORDER BY messages.sent_at DESC LIMIT ?;
      """
      bindings.append(.int(Int64(limit)))
      let statement = try database.prepare(sql).bind(bindings)
      var hits: [SearchHit] = []
      try statement.forEachRow { row in
        guard let message = Self.message(in: row) else { return }
        // L'onglet, lui, se décide en Swift : le SQL n'est qu'un pré-filtre.
        if let facet, !FacetedSearch.matches(message, facet: facet) { return }
        hits.append(
          SearchHit(roomID: row.string(1), conversationID: row.string(2), message: message)
        )
      }
      return hits
    }
  }

  /// Les résultats d'un onglet, rendus dans le moule que les deux plateformes
  /// affichent déjà. Seules les conversations du Relais sont concernées : un
  /// fil iMessage n'est pas dans cette base et garde son chemin d'origine.
  func facetHits(
    in conversations: [Conversation],
    facet: MessageFacet,
    query: String = "",
    limit: Int = 500
  ) -> [FacetedSearch.Hit] {
    let relay = conversations.filter { $0.network.livesOnRelay }
    guard !relay.isEmpty, !facet.isConversationFacet else { return [] }
    var byID: [String: Conversation] = [:]
    for conversation in relay { byID[conversation.id] = conversation }
    return search(query: query, facet: facet, roomIDs: Set(relay.map(\.transportKey)), limit: limit)
      .compactMap { hit in
        guard let conversation = byID[hit.conversationID] else { return nil }
        return FacetedSearch.Hit(conversation: conversation, message: hit.message)
      }
  }

  /// Le corps replié des messages qui répondent à la question, par
  /// conversation — ce que `ConversationSearch.filter` attend comme index.
  ///
  /// Construit pour **cette** question seulement, plutôt que pour tout
  /// l'historique : c'est ce qui remplace l'index qu'on tenait en mémoire.
  func searchIndex(query: String, limit: Int = 500) -> [String: String] {
    var byConversation: [String: [ChatMessage]] = [:]
    for hit in search(query: query, limit: limit) {
      byConversation[hit.conversationID, default: []].append(hit.message)
    }
    return byConversation.mapValues { ConversationSearch.blob(for: $0) }
  }

  /// Le pré-filtre SQL d'un onglet. `nil` = rien à pré-filtrer, c'est Swift qui
  /// tranchera (les liens, qu'aucune colonne ne décrit).
  private static func predicate(for facet: MessageFacet) -> String? {
    switch facet {
    case .images:
      return "messages.attachment_types LIKE '%image/%'"
    case .videos:
      return "messages.attachment_types LIKE '%video/%'"
    case .files:
      // Tout ce qui est joint sans être une image ni une vidéo : un vocal, un
      // PDF, un `.zip`. Rien ne doit tomber entre deux onglets.
      return "messages.attachment_types <> ''"
    case .links:
      return "(messages.text LIKE '%http://%' OR messages.text LIKE '%https://%')"
    case .drafts:
      return nil
    }
  }

  /// La question de l'utilisateur traduite en requête FTS5, et **jamais**
  /// injectée telle quelle : les guillemets, les `*`, les `NEAR` et les `-` de
  /// FTS5 feraient de « c'est-à-dire » une syntaxe invalide.
  ///
  /// Chaque mot devient un préfixe entre guillemets — taper « pho » trouve
  /// « photo », comme partout ailleurs dans l'app.
  static func ftsQuery(_ raw: String) -> String {
    let tokens = raw
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return "" }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
  }
}
