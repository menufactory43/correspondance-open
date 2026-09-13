import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

@MainActor
extension TUIApp {
  func handleOverlayKey(_ key: KeyEvent) {
    guard let overlay = ui.overlay else { return }
    if key == KeyEvent(.escape) || key == .control("c") {
      ui.overlay = nil
      return
    }
    switch overlay {
    case .help:
      ui.overlay = nil

    case .search(var state):
      switch key {
      case KeyEvent(.down), .control("n"), KeyEvent(.tab):
        state.index = min(state.index + 1, max(0, state.results.count - 1))
        ui.overlay = .search(state)
      case KeyEvent(.up), .control("p"), KeyEvent(.tab, .shift):
        state.index = max(0, state.index - 1)
        ui.overlay = .search(state)
      case KeyEvent(.enter):
        ui.overlay = nil
        guard state.results.indices.contains(state.index) else { return }
        let id = state.results[state.index].conversationID
        ui.mode = .inbox
        // Une conversation archivée se trouve dans l'archive : on y va.
        if store.isArchived(id), store.scope != .archive { store.scope = .archive }
        openInInbox(id)
        ui.pane = .thread
      default:
        if state.editor.handle(key) {
          ui.overlay = .search(state)
          refreshSearch()
        }
      }

    case .reactions(let conversationID, let messageID, var index):
      let reactions = RelayStore.quickReactions
      var chosen: Int?
      switch key {
      case KeyEvent(.left), .char("h"): index = max(0, index - 1)
      case KeyEvent(.right), .char("l"): index = min(reactions.count - 1, index + 1)
      case KeyEvent(.enter): chosen = index
      default:
        if case .character(let c) = key.key, key.modifiers.isEmpty,
           let digit = c.wholeNumberValue, (1...reactions.count).contains(digit) {
          chosen = digit - 1
        }
      }
      if let chosen {
        ui.overlay = nil
        let emoji = reactions[chosen]
        Task { await store.react(conversationID: conversationID, messageID: messageID, emoji: emoji) }
      } else {
        ui.overlay = .reactions(conversationID: conversationID, messageID: messageID, index: index)
      }

    case .reminder(let conversationID, var index):
      let items = reminderItems(conversationID)
      switch key {
      case KeyEvent(.down), .char("j"): index = min(items.count - 1, index + 1)
      case KeyEvent(.up), .char("k"): index = max(0, index - 1)
      case KeyEvent(.enter):
        ui.overlay = nil
        guard items.indices.contains(index) else { return }
        let date = items[index].date
        store.setReminder(date, conversationID: conversationID)
        toast(date.map { "Rappel \(Dates.moment($0))" } ?? "Rappel retiré")
        if date != nil, ui.mode == .inbox, ui.pane == .thread, store.scope == .inbox { ui.pane = .list }
        return
      default: break
      }
      ui.overlay = .reminder(conversationID: conversationID, index: index)

    case .forward(var state):
      let targets = store.forwardTargets(state.editor.text)
      switch key {
      case KeyEvent(.down), .control("n"), KeyEvent(.tab): state.index = min(targets.count - 1, state.index + 1)
      case KeyEvent(.up), .control("p"): state.index = max(0, state.index - 1)
      case KeyEvent(.enter):
        ui.overlay = nil
        guard targets.indices.contains(state.index),
              let message = store.visibleMessages(state.conversationID).first(where: { $0.id == state.messageID })
        else { return }
        let target = targets[state.index]
        Task { await store.forward(message, to: target.id) }
        toast("Transféré à \(target.title)")
        return
      default:
        if state.editor.handle(key) { state.index = 0 }
      }
      ui.overlay = .forward(state)

    case .confirm(let state):
      switch key {
      case .char("y"), .char("o"), KeyEvent(.enter):
        ui.overlay = nil
        perform(state.action)
      case .char("n"):
        ui.overlay = nil
      default:
        break
      }

    case .attach(let conversationID, var editor, _):
      switch key {
      case KeyEvent(.enter):
        let path = Self.unquotePath(editor.text)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
          ui.overlay = .attach(conversationID: conversationID, editor: editor, error: "Pas de fichier à ce chemin.")
          return
        }
        store.addAttachment(path, conversationID: conversationID)
        ui.overlay = nil
        beginComposing(conversationID)
        toast("Joint : \(URL(fileURLWithPath: path).lastPathComponent)")
      case KeyEvent(.tab):
        editor.setText(Self.completePath(editor.text))
        ui.overlay = .attach(conversationID: conversationID, editor: editor, error: nil)
      default:
        _ = editor.handle(key)
        ui.overlay = .attach(conversationID: conversationID, editor: editor, error: nil)
      }

    case .poll(let conversationID, let messageID, var index):
      let count = store.visibleMessages(conversationID).first(where: { $0.id == messageID })?.poll?.answers.count ?? 0
      switch key {
      case KeyEvent(.down), .char("j"): index = min(max(0, count - 1), index + 1)
      case KeyEvent(.up), .char("k"): index = max(0, index - 1)
      case KeyEvent(.enter):
        ui.overlay = nil
        guard let answer = store.visibleMessages(conversationID).first(where: { $0.id == messageID })?.poll?.answers[safe: index] else { return }
        Task { await store.votePoll(conversationID: conversationID, messageID: messageID, answerID: answer.id) }
        return
      default: break
      }
      ui.overlay = .poll(conversationID: conversationID, messageID: messageID, index: index)

    case .filters(var index):
      let items = filterItems()
      switch key {
      case KeyEvent(.down), .char("j"): index = min(items.count - 1, index + 1)
      case KeyEvent(.up), .char("k"): index = max(0, index - 1)
      case KeyEvent(.enter):
        ui.overlay = nil
        guard items.indices.contains(index) else { return }
        items[index].apply(store)
        ui.listTop = 0
        return
      default: break
      }
      ui.overlay = .filters(index: index)
    }
  }

  private func perform(_ action: UIState.ConfirmAction) {
    switch action {
    case .deleteEverywhere(let conversationID, let messageID):
      ui.viewports[conversationID]?.cursorMessageID = nil
      Task { await store.deleteEverywhere(messageID: messageID, conversationID: conversationID) }
      toast("Supprimé pour tous")
    case .archiveAllRead:
      let count = store.readArchivableConversations.count
      store.archiveAllRead()
      toast("\(count) conversation\(count > 1 ? "s" : "") archivée\(count > 1 ? "s" : "")")
    case .reload:
      threadCache.removeAll()
      ui.viewports = [:]
      Task { await store.reloadFromRelay() }
      toast("Rechargement depuis le Relais…")
    case .signOut:
      Task { await store.signOut() }
    case .declineRequest(let conversationID):
      store.decideRequest(.declined, conversationID: conversationID)
      toast("Demande refusée")
    }
  }

  // MARK: - Recherche

  /// Les fils dont le titre ou le contenu répond, par la base locale (FTS) :
  /// on retrouve un mot d'un fil qu'on n'a pas ouvert depuis des mois.
  func refreshSearch() {
    guard case .search(var state) = ui.overlay else { return }
    let query = state.editor.text.trimmingCharacters(in: .whitespaces)
    state.query = query
    state.index = 0
    if query.isEmpty {
      state.results = []
    } else {
      var index = store.searchIndex(query: query)
      let needle = query.lowercased()
      let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      // La démonstration rend le texte de tous les fils ; la base, seulement ceux qui répondent.
      if store.isDemo {
        index = index.filter { $0.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded) }
      }
      let hits = store.conversations.filter { $0.title.lowercased().contains(needle) || index[$0.id] != nil }
      // Les titres d'abord, puis le contenu ; le plus récent en tête dans chaque groupe.
      let sorted = hits.sorted { a, b in
        let aTitle = a.title.lowercased().contains(needle)
        let bTitle = b.title.lowercased().contains(needle)
        if aTitle != bTitle { return aTitle }
        return a.lastMessageAt > b.lastMessageAt
      }
      state.results = sorted.prefix(60).map { conversation in
        UIState.SearchResult(conversationID: conversation.id, title: conversation.title, network: conversation.network, excerpt: index[conversation.id] ?? conversation.preview)
      }
    }
    ui.overlay = .search(state)
  }

  // MARK: - Connexion

  func handleLoginKey(_ key: KeyEvent) {
    if ui.login.link == .working {
      if key == .control("c") { quit() }
      return
    }
    switch key {
    case .control("c"):
      quit()
    case KeyEvent(.tab), KeyEvent(.down):
      ui.login.field = (ui.login.field + 1) % UIState.LoginForm.fieldCount
    case KeyEvent(.tab, .shift), KeyEvent(.up):
      ui.login.field = (ui.login.field + UIState.LoginForm.fieldCount - 1) % UIState.LoginForm.fieldCount
    case KeyEvent(.escape) where ui.login.field == 0:
      ui.login.link = .idle
      ui.login.linkPassword = LineEditor()
    case KeyEvent(.enter):
      if ui.login.field == 0 { linkFromAppSession() } else { submitLogin() }
    default:
      guard var editor = ui.login[field: ui.login.field] else { return }
      if editor.handle(key) { ui.login[field: ui.login.field] = editor }
    }
  }

  /// La connexion sans rien taper : la session de l'app demande au Relais un
  /// jeton pour ce terminal, qui devient un appareil à part entière.
  func linkFromAppSession() {
    var password: String?
    var sessionUIA: String?
    if case .needsPassword(let uia, _) = ui.login.link {
      guard !ui.login.linkPassword.isEmpty else { return }
      password = ui.login.linkPassword.text
      sessionUIA = uia
    }
    store.connectionError = nil
    ui.login.link = .working
    Task { @MainActor [weak self] in
      // Le Trousseau peut demander l'autorisation à l'utilisateur et bloquer
      // de longues secondes : jamais sur le fil de l'écran.
      let found = await Task.detached(priority: .userInitiated) { RelayStore.sessionDeLApp() }.value
      guard let self else { return }
      guard let parent = found else {
        self.ui.login.link = .idle
        self.store.connectionError = "Aucune session d’app lisible sur cette machine : connecte d’abord l’app Correspondance (ou autorise l’accès au Trousseau), ou utilise un code d’appairage."
        self.setNeedsRender()
        return
      }
      let issue = await self.store.connecterDepuisSession(parent, motDePasse: password, sessionUIA: sessionUIA)
      self.ui.login.linkPassword = LineEditor()
      switch issue {
      case .connecte:
        self.ui.login.link = .idle
        self.toast("Terminal connecté comme nouvel appareil")
      case .motDePasseRequis(let uia):
        self.ui.login.link = .needsPassword(sessionUIA: uia, user: MatrixIdentity.localpart(parent.userID))
        self.ui.login.field = 0
      case .echec(let message):
        self.ui.login.link = .idle
        self.store.connectionError = message
      }
      self.setNeedsRender()
    }
  }

  private func submitLogin() {
    store.connectionError = nil
    let code = ui.login.code.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !code.isEmpty {
      guard let pairing = RelayPairingCode(encoded: code) else {
        store.connectionError = "Ce code d’appairage ne se lit pas."
        return
      }
      guard !pairing.isExpired() else {
        store.connectionError = "Ce code d’appairage a expiré — l’installeur du Relais en donne un neuf."
        return
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        let note = await self.store.connecterParLeCode(pairing)
        self.toast(note)
      }
      return
    }
    let homeserver = ui.login.homeserver.text
    let user = ui.login.user.text
    let password = ui.login.password.text
    guard !homeserver.isEmpty, !user.isEmpty, !password.isEmpty else {
      store.connectionError = "Il faut un code d’appairage, ou l’adresse, l’utilisateur et le mot de passe."
      return
    }
    Task { @MainActor [weak self] in
      await self?.store.connect(homeserver: homeserver, user: user, password: password)
      self?.ui.login.password = LineEditor()
      self?.setNeedsRender()
    }
  }

  // MARK: - Chemins

  /// Complète un chemin jusqu'au plus long préfixe commun, comme un shell.
  static func completePath(_ raw: String) -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    let directory: String
    let prefix: String
    if expanded.hasSuffix("/") {
      directory = expanded
      prefix = ""
    } else {
      directory = (expanded as NSString).deletingLastPathComponent
      prefix = (expanded as NSString).lastPathComponent
    }
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "/" : directory) else { return raw }
    let matches = entries.filter { $0.hasPrefix(prefix) && (!$0.hasPrefix(".") || prefix.hasPrefix(".")) }.sorted()
    guard let first = matches.first else { return raw }
    var common = first
    for match in matches.dropFirst() {
      while !match.hasPrefix(common) { common.removeLast() }
    }
    var completed = (directory as NSString).appendingPathComponent(common)
    var isDirectory: ObjCBool = false
    if matches.count == 1, FileManager.default.fileExists(atPath: completed, isDirectory: &isDirectory), isDirectory.boolValue {
      completed += "/"
    }
    return completed
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
