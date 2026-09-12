import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

@MainActor
extension TUIApp {
  // MARK: - Aiguillage

  func handleKey(_ key: KeyEvent) {
    // Ce qui vaut partout, même au milieu d'une saisie.
    if key == .control("z") { suspend(); return }
    if key == .control("l") {
      renderer.invalidate()
      return
    }
    if key != .control("c") { ui.pendingQuit = false }

    if store.session == .disconnected {
      handleLoginKey(key)
      return
    }
    guard store.session == .connected else {
      if key == .control("c") || key == .char("q") { quit() }
      return
    }
    if ui.overlay != nil {
      handleOverlayKey(key)
      return
    }
    if ui.isComposing {
      handleComposerKey(key)
      return
    }
    handleNormalKey(key)
  }

  /// La conversation que les gestes visent : celle de Focus, ou la sélection de l'inbox.
  var targetConversationID: String? {
    switch ui.mode {
    case .focus: return store.focusConversationID
    case .inbox: return ui.pane == .thread ? store.selectedConversationID : (ui.listSelectionID ?? store.selectedConversationID)
    }
  }

  /// Le fil affiché qui reçoit les gestes de message.
  var threadConversationID: String? {
    switch ui.mode {
    case .focus: return store.focusConversationID
    case .inbox: return store.selectedConversationID
    }
  }

  private var threadHasKeyboard: Bool { ui.mode == .focus || ui.pane == .thread }

  // MARK: - Mode normal

  private func handleNormalKey(_ key: KeyEvent) {
    if handleGlobalKey(key) { return }
    if threadHasKeyboard, handleThreadKey(key) { return }
    if ui.mode == .inbox, ui.pane == .list, handleListKey(key) { return }
    if handleConversationKey(key) { return }
  }

  private func handleGlobalKey(_ key: KeyEvent) -> Bool {
    switch key {
    case .control("c"), .char("q"):
      quit()
    case .char("1"):
      ui.mode = .focus
      if store.focusConversationID == nil, let id = targetConversationID, store.focusQueue.contains(where: { $0.id == id }) {
        store.focusConversationID = id
      }
    case .char("2"):
      ui.mode = .inbox
      if ui.listSelectionID == nil {
        ui.listSelectionID = store.focusConversationID ?? store.visibleConversations.first?.id
      }
      // Sur un écran large, le fil de droite montre tout de suite la sélection.
      if store.selectedConversationID == nil, canvas.width >= 90, let id = ui.listSelectionID {
        store.selectedConversationID = id
        scheduleOpen(id)
      }
    case .char("?"):
      ui.overlay = .help
    case .char("/"):
      ui.overlay = .search(UIState.SearchState())
    case .char("I"):
      store.isIncognito.toggle()
      toast(store.isIncognito ? "Incognito : ouvrir un fil ne le marque plus lu" : "Incognito levé")
    case .char("R"):
      ui.overlay = .confirm(.init(title: "Recharger", detail: "Vider la base locale de ce terminal et tout relire depuis le Relais ?", action: .reload))
    case .char("N"):
      ui.mode = .inbox
      ui.pane = .thread
      Task { @MainActor [weak self] in
        await self?.store.openSelfNote()
        self?.setNeedsRender()
      }
    default:
      return false
    }
    return true
  }

  // MARK: Liste

  private func handleListKey(_ key: KeyEvent) -> Bool {
    let list = store.visibleConversations
    switch key {
    case .char("j"), KeyEvent(.down):
      moveListSelection(by: 1, in: list)
    case .char("k"), KeyEvent(.up):
      moveListSelection(by: -1, in: list)
    case KeyEvent(.pageDown), .control("d"), .control("f"):
      moveListSelection(by: ui.listPageSize, in: list)
    case KeyEvent(.pageUp), .control("u"), .control("b"):
      moveListSelection(by: -ui.listPageSize, in: list)
    case .char("g"), KeyEvent(.home):
      moveListSelection(to: 0, in: list)
    case .char("G"), KeyEvent(.end):
      moveListSelection(to: list.count - 1, in: list)
    case KeyEvent(.enter), .char("l"), KeyEvent(.right), .char("o"):
      guard let id = ui.listSelectionID else { return true }
      openInInbox(id)
      ui.pane = .thread
    case .char("i"):
      guard let id = ui.listSelectionID else { return true }
      openInInbox(id)
      ui.pane = .thread
      beginComposing(id)
    case .char("s"), KeyEvent(.tab):
      cycleScope(by: 1)
    case .char("S"), KeyEvent(.tab, .shift):
      cycleScope(by: -1)
    case .char("f"):
      ui.overlay = .filters(index: 0)
    case .char("A"):
      let count = store.readArchivableConversations.count
      guard count > 0 else {
        toast("Rien de lu à archiver")
        return true
      }
      ui.overlay = .confirm(.init(title: "Archiver le lu", detail: "Archiver \(count) conversation\(count > 1 ? "s" : "") déjà lue\(count > 1 ? "s" : "") ? Les épinglées et les non lues restent.", action: .archiveAllRead))
    case .char("x"):
      guard let id = ui.listSelectionID, store.isRequest(id) else { return false }
      store.decideRequest(.accepted, conversationID: id)
      toast("Demande acceptée")
    case .char("X"):
      guard let id = ui.listSelectionID, store.isRequest(id) else { return false }
      ui.overlay = .confirm(.init(title: "Refuser", detail: "Refuser cette demande ? La conversation est rangée et ne redemandera plus.", action: .declineRequest(conversationID: id)))
    default:
      return false
    }
    return true
  }

  private func moveListSelection(by delta: Int, in list: [Conversation]) {
    guard !list.isEmpty else { return }
    let current = list.firstIndex(where: { $0.id == ui.listSelectionID }) ?? 0
    moveListSelection(to: current + delta, in: list)
  }

  private func moveListSelection(to index: Int, in list: [Conversation]) {
    guard !list.isEmpty else { return }
    let clamped = max(0, min(list.count - 1, index))
    ui.listSelectionID = list[clamped].id
    ui.listLastIndex = clamped
    // Sur un écran large, le fil suit la sélection — ouvert après un repos.
    if canvas.width >= 90 {
      store.selectedConversationID = list[clamped].id
      scheduleOpen(list[clamped].id)
    }
  }

  func openInInbox(_ id: String) {
    ui.listSelectionID = id
    store.selectedConversationID = id
    scheduleOpen(id, delay: .zero)
  }

  private func cycleScope(by delta: Int) {
    let all = InboxScope.allCases
    let index = all.firstIndex(of: store.scope) ?? 0
    store.scope = all[(index + delta + all.count) % all.count]
    ui.listTop = 0
    ui.listLastIndex = 0
    ui.listSelectionID = nil
  }

  // MARK: Conversation (Focus, liste ou fil)

  private func handleConversationKey(_ key: KeyEvent) -> Bool {
    guard let id = targetConversationID else { return false }
    switch key {
    case .char("a"):
      if ui.mode == .focus {
        let title = store.conversation(id)?.title ?? ""
        store.focusArchiveAndAdvance()
        toast("« \(title) » archivée")
      } else {
        let archived = !store.isArchived(id)
        store.setArchived(archived, conversationID: id)
        toast(archived ? "Archivée" : "Revenue dans l’inbox")
        if ui.pane == .thread, archived, store.scope == .inbox { ui.pane = .list }
      }
    case .char("P"):
      store.togglePinned(id)
      toast(store.isPinned(id) ? "Épinglée" : "Désépinglée")
    case .char("m"):
      store.toggleMuted(id)
      toast(store.isMuted(id) ? "Muette" : "Plus muette")
    case .char("z"):
      ui.overlay = .reminder(conversationID: id, index: 0)
    case .char("M"):
      Task { await store.markRead(conversationID: id) }
      toast("Marquée lue")
    case .char("n") where ui.mode == .focus, KeyEvent(.right) where ui.mode == .focus:
      store.focusNext()
    case .char("p") where ui.mode == .focus, KeyEvent(.left) where ui.mode == .focus:
      store.focusPrevious()
    default:
      return false
    }
    return true
  }

  // MARK: Fil

  private func handleThreadKey(_ key: KeyEvent) -> Bool {
    guard let id = threadConversationID else { return false }
    let messages = store.visibleMessages(id)
    var viewport = ui.viewports[id] ?? UIState.ThreadViewport()
    defer { ui.viewports[id] = viewport }
    let cursorIndex = viewport.cursorMessageID.flatMap { cursor in messages.firstIndex(where: { $0.id == cursor }) }
    let selected = cursorIndex.map { messages[$0] }
    // Sans curseur, les gestes de message visent le dernier message.
    let target = selected ?? messages.last

    switch key {
    case .char("k"), KeyEvent(.up):
      guard !messages.isEmpty else { return true }
      let next = max(0, (cursorIndex ?? messages.count) - 1)
      viewport.cursorMessageID = messages[next].id
      if next == 0 { requestOlderFromKeyboard(id) }
    case .char("j"), KeyEvent(.down):
      guard let cursorIndex else { return true }
      if cursorIndex + 1 < messages.count {
        viewport.cursorMessageID = messages[cursorIndex + 1].id
      } else {
        viewport.cursorMessageID = nil
        viewport.scrollFromBottom = 0
      }
    case .control("u"), KeyEvent(.pageUp):
      viewport.cursorMessageID = nil
      viewport.scrollFromBottom += max(1, ui.threadPageSize / 2)
    case .control("d"), KeyEvent(.pageDown):
      viewport.cursorMessageID = nil
      viewport.scrollFromBottom = max(0, viewport.scrollFromBottom - max(1, ui.threadPageSize / 2))
    case .char("g"), KeyEvent(.home):
      viewport.cursorMessageID = messages.first?.id
      requestOlderFromKeyboard(id)
    case .char("G"), KeyEvent(.end):
      viewport.cursorMessageID = nil
      viewport.scrollFromBottom = 0
    case KeyEvent(.escape), .char("h"), KeyEvent(.left):
      if viewport.cursorMessageID != nil {
        viewport.cursorMessageID = nil
        viewport.scrollFromBottom = 0
      } else if ui.mode == .inbox {
        ui.pane = .list
      } else {
        return false // ← en Focus : conversation précédente
      }
    case .char("i"), KeyEvent(.enter):
      viewport.cursorMessageID = nil
      beginComposing(id)
    case .char("r"):
      guard let target, !target.isSystemEvent else { return true }
      store.setReplyTarget(target.id, conversationID: id)
      viewport.cursorMessageID = nil
      beginComposing(id)
    case .char("e"):
      guard let target = selected ?? messages.last(where: { store.canEdit($0) }) else { return true }
      guard store.canEdit(target) else {
        toast("Ce message ne peut plus être corrigé", isError: true)
        return true
      }
      viewport.cursorMessageID = nil
      beginComposing(id)
      store.beginEditing(target, conversationID: id)
    case .char("+"), .char("="):
      guard let target, !target.isSystemEvent else { return true }
      ui.overlay = .reactions(conversationID: id, messageID: target.id, index: 0)
    case .char("F"):
      guard let target, store.canForward(target) else {
        toast("Rien à transférer dans ce message", isError: true)
        return true
      }
      ui.overlay = .forward(.init(conversationID: id, messageID: target.id))
    case .char("y"):
      guard let target, !target.text.isEmpty else { return true }
      terminal.write(TerminalSequences.copyToClipboard(target.text))
      toast("Copié")
    case .char("o"):
      guard let target else { return true }
      openAttachment(of: target)
    case .char("D"):
      guard let target, store.canDeleteEverywhere(target) else {
        toast("Suppression pour tous impossible ici", isError: true)
        return true
      }
      ui.overlay = .confirm(.init(title: "Supprimer pour tous", detail: "« \(TextLayout.truncate(TextLayout.singleLine(target.sidebarPreviewText), to: 80)) » disparaîtra chez tout le monde.", action: .deleteEverywhere(conversationID: id, messageID: target.id)))
    case .char("H"):
      guard let target else { return true }
      store.hide(messageID: target.id, conversationID: id)
      viewport.cursorMessageID = nil
      toast("Message masqué sur tes appareils")
    case .char("u"):
      guard let undoable = messages.last(where: { store.canUndoSend($0.id) }) else { return false }
      store.undoSend(undoable.id)
      viewport.cursorMessageID = nil
      beginComposing(id)
      toast("Envoi annulé")
    case .char("V"):
      guard let poll = messages.reversed().first(where: { $0.poll != nil && ($0.id == target?.id || selected == nil) }), poll.poll?.isClosed == false else {
        toast("Pas de sondage ouvert ici", isError: true)
        return true
      }
      ui.overlay = .poll(conversationID: id, messageID: poll.id, index: 0)
    case .char("S"), .char("E"), .char("X"):
      guard let proposal = (selected?.isAgentProposal == true ? selected : messages.last(where: \.isAgentProposal)) else { return false }
      if key == .char("S") {
        Task { await store.sendAgentProposal(proposal, conversationID: id) }
        toast("Proposition envoyée")
      } else if key == .char("E") {
        store.editAgentProposal(proposal, conversationID: id)
        viewport.cursorMessageID = nil
        beginComposing(id)
      } else {
        store.ignoreAgentProposal(proposal, conversationID: id)
      }
    default:
      return false
    }
    return true
  }

  private func requestOlderFromKeyboard(_ id: String) {
    Task { @MainActor [weak self] in await self?.store.loadOlder(conversationID: id) }
  }

  private func openAttachment(of message: ChatMessage) {
    let files = message.attachments.map(AttachmentRepair.repaired).compactMap(\.resolvedFileURL)
    if let file = files.first {
      if Platform.open(file) { toast("Ouvert : \(file.lastPathComponent)") } else { toast("Rien n’a su ouvrir \(file.lastPathComponent)", isError: true) }
      return
    }
    if let link = TextLinks.detect(in: message.text).first?.url ?? message.linkPreview?.webURL {
      if Platform.open(link) { toast("Ouvert dans le navigateur") }
      return
    }
    toast("Pas de pièce jointe à ouvrir", isError: true)
  }

  // MARK: - Composer

  func beginComposing(_ conversationID: String) {
    if ui.composerConversationID != conversationID {
      ui.composerConversationID = conversationID
      let draft = store.draftText(conversationID)
      ui.composer = LineEditor(draft, allowsNewlines: true)
      ui.composerSynced = draft
    }
    ui.isComposing = true
  }

  private func commitComposer() {
    guard let id = ui.composerConversationID else { return }
    let text = ui.composer.text
    guard text != ui.composerSynced else { return }
    ui.composerSynced = text
    store.setDraft(text, conversationID: id)
  }

  private func handleComposerKey(_ key: KeyEvent) {
    guard let id = ui.composerConversationID else {
      ui.isComposing = false
      return
    }
    switch key {
    case KeyEvent(.escape), .control("c"):
      if store.editingMessage(id) != nil {
        store.endEditing(id)
      } else if store.replyTarget(id) != nil {
        store.setReplyTarget(nil, conversationID: id)
      } else {
        ui.isComposing = false
      }
      return
    case KeyEvent(.enter):
      commitComposer()
      guard store.canSend(id) || store.editingMessage(id) != nil else { return }
      Task { @MainActor [weak self] in
        await self?.store.send(conversationID: id)
        self?.setNeedsRender()
      }
      ui.viewports[id]?.scrollFromBottom = 0
      return
    case .control("o"):
      ui.overlay = .attach(conversationID: id, editor: LineEditor(FileManager.default.homeDirectoryForCurrentUser.path + "/"), error: nil)
      return
    case .control("x"):
      for path in store.attachments(id) { store.removeAttachment(path, conversationID: id) }
      return
    case KeyEvent(.up) where ui.composer.isEmpty:
      // ↑ dans un composer vide : corriger mon dernier message, comme partout.
      if let last = store.visibleMessages(id).last(where: { store.canEdit($0) }) {
        store.beginEditing(last, conversationID: id)
      }
      return
    default:
      break
    }
    if ui.composer.handle(key, layoutWidth: ui.composerWidth) {
      commitComposer()
    }
  }

  // MARK: - Collage

  func handlePaste(_ text: String) {
    if store.session == .disconnected {
      var editor = ui.login[field: ui.login.field]
      editor.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
      ui.login[field: ui.login.field] = editor
      return
    }
    if case .attach(let id, var editor, _) = ui.overlay {
      editor.setText(Self.unquotePath(text))
      ui.overlay = .attach(conversationID: id, editor: editor, error: nil)
      return
    }
    if case .search(var state) = ui.overlay {
      state.editor.insert(text)
      ui.overlay = .search(state)
      refreshSearch()
      return
    }
    if case .forward(var state) = ui.overlay {
      state.editor.insert(text)
      ui.overlay = .forward(state)
      return
    }
    guard ui.overlay == nil, let id = threadConversationID else { return }
    // Glisser un fichier dans le terminal colle son chemin : on le joint.
    let paths = Self.pastedPaths(text)
    if !paths.isEmpty {
      for path in paths { store.addAttachment(path, conversationID: id) }
      beginComposing(id)
      toast(paths.count == 1 ? "Fichier joint" : "\(paths.count) fichiers joints")
      return
    }
    beginComposing(id)
    ui.composer.insert(text)
    commitComposer()
  }

  /// Les chemins qu'un glisser-déposer colle : échappés (`\ `) ou entre guillemets.
  static func pastedPaths(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") || trimmed.hasPrefix("'/") || trimmed.hasPrefix("\"/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("file://") else { return [] }
    var paths: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for character in trimmed {
      if escaped {
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if let open = quote {
        if character == open { quote = nil } else { current.append(character) }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if character == " " || character == "\n" {
        if !current.isEmpty { paths.append(current) }
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { paths.append(current) }
    let resolved = paths.map(unquotePath)
    guard resolved.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return [] }
    return resolved
  }

  static func unquotePath(_ raw: String) -> String {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
    if (path.hasPrefix("'") && path.hasSuffix("'")) || (path.hasPrefix("\"") && path.hasSuffix("\"")), path.count >= 2 {
      path = String(path.dropFirst().dropLast())
    }
    path = path.replacingOccurrences(of: "\\ ", with: " ")
    return (path as NSString).expandingTildeInPath
  }

  // MARK: - Souris

  func handleMouse(_ mouse: MouseEvent) {
    guard store.session == .connected, ui.overlay == nil else { return }
    switch mouse.kind {
    case .scrollUp, .scrollDown:
      let delta = mouse.kind == .scrollUp ? 3 : -3
      if ui.mode == .inbox, let frame = ui.listRowFrames.first?.0, mouse.x < frame.maxX {
        moveListSelection(by: -delta / 3, in: store.visibleConversations)
      } else if let id = threadConversationID {
        var viewport = ui.viewports[id] ?? UIState.ThreadViewport()
        viewport.cursorMessageID = nil
        viewport.scrollFromBottom = max(0, viewport.scrollFromBottom + delta)
        ui.viewports[id] = viewport
      }
    case .press(button: 0):
      if ui.mode == .inbox, let row = ui.listRowFrames.first(where: { $0.0.contains(x: mouse.x, y: mouse.y) }) {
        if ui.listSelectionID == row.1, store.selectedConversationID == row.1 {
          ui.pane = .thread
        }
        ui.listSelectionID = row.1
        openInInbox(row.1)
        if canvas.width < 90 { ui.pane = .thread } else { ui.pane = .list }
        return
      }
      if let id = threadConversationID, let hit = ui.threadLineFrames.first(where: { $0.0 == mouse.y }) {
        if ui.mode == .inbox { ui.pane = .thread }
        ui.isComposing = false
        ui.viewports[id, default: UIState.ThreadViewport()].cursorMessageID = hit.1
      }
    default:
      break
    }
  }
}
