import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

@MainActor
extension TUIApp {
  /// Une image entière de l'écran. Tout ce qui est lu ici est observé.
  func draw() {
    let bounds = canvas.bounds
    guard bounds.width >= 20, bounds.height >= 6 else {
      canvas.put("Fenêtre trop petite", x: 0, y: 0, maxWidth: bounds.width, style: Theme.warning)
      return
    }

    switch store.session {
    case .unknown:
      drawCentered(["Correspondance", "Lecture de la session…"], in: bounds)
      return
    case .connecting:
      drawCentered(["Correspondance", "Connexion au Relais…"], in: bounds)
      return
    case .disconnected:
      drawLogin(in: bounds)
      return
    case .connected:
      break
    }

    let (main, status) = bounds.splitBottom(1)
    switch ui.mode {
    case .focus: drawFocus(in: main)
    case .inbox: drawInbox(in: main)
    }
    drawStatusBar(in: status)
    drawOverlay(in: bounds)
  }

  func drawCentered(_ lines: [String], in rect: Rect) {
    let top = rect.y + max(0, (rect.height - lines.count) / 2)
    for (index, line) in lines.enumerated() {
      let x = rect.x + max(0, (rect.width - CellWidth.of(line)) / 2)
      canvas.put(line, x: x, y: top + index, maxWidth: rect.width, style: index == 0 ? Theme.strong : Theme.muted)
    }
  }

  // MARK: - Focus

  func drawFocus(in rect: Rect) {
    let queue = store.focusQueue
    guard let conversation = store.focusConversation() else {
      drawCentered(["La file est vide.", "Rien n’attend de réponse. 2 pour l’inbox."], in: rect)
      return
    }
    if store.focusConversationID != ui.lastOpenedFocusID {
      ui.lastOpenedFocusID = store.focusConversationID
      scheduleOpen(conversation.id, delay: .milliseconds(120))
    }
    let (header, body) = rect.splitTop(2)
    let position = (queue.firstIndex(where: { $0.id == conversation.id }) ?? 0) + 1
    drawConversationHeader(conversation, prefix: "Focus \(position)/\(queue.count)", in: header)
    drawThreadPane(conversationID: conversation.id, in: body.inset(dx: 1), isActive: true)
  }

  func drawConversationHeader(_ conversation: Conversation, prefix: String?, in rect: Rect) {
    var x = rect.x + 1
    if let prefix {
      x = canvas.put(prefix, x: x, y: rect.y, style: Theme.accentStrong, clip: rect)
      x = canvas.put("  ", x: x, y: rect.y, style: .plain, clip: rect)
    }
    let badges = conversationBadges(conversation.id)
    let badgesWidth = CellWidth.of(badges)
    let tag = Theme.networkTag(conversation.network)
    x = canvas.put(conversation.title, x: x, y: rect.y, maxWidth: max(4, rect.maxX - x - CellWidth.of(tag) - badgesWidth - 4), style: Theme.strong, clip: rect)
    x = canvas.put("  ", x: x, y: rect.y, style: .plain, clip: rect)
    x = canvas.put(tag, x: x, y: rect.y, style: Theme.network(conversation.network), clip: rect)
    if let typing = store.typingLabel(conversation.id) {
      x = canvas.put("  \(typing)", x: x, y: rect.y, style: Theme.accent.with(.italic), clip: rect)
    }
    canvas.put(badges, x: rect.maxX - badgesWidth - 1, y: rect.y, style: Theme.muted, clip: rect)
    if rect.height > 1 {
      canvas.put(String(repeating: Theme.Box.horizontal, count: rect.width), x: rect.x, y: rect.y + 1, style: Theme.border, clip: rect)
    }
  }

  func conversationBadges(_ id: String) -> String {
    var badges: [String] = []
    if store.isPinned(id) { badges.append("épinglé") }
    if store.isMuted(id) { badges.append("muet") }
    if let reminder = store.reminder(id) { badges.append("rappel \(reminder.labelFR())") }
    if store.isRequest(id) { badges.append("demande") }
    if store.isArchived(id) { badges.append("archivé") }
    return badges.joined(separator: " · ")
  }

  // MARK: - Inbox

  func drawInbox(in rect: Rect) {
    let wide = rect.width >= 90
    if !wide {
      if ui.pane == .thread, let id = store.selectedConversationID, let conversation = store.conversation(id) {
        let (header, body) = rect.splitTop(2)
        drawConversationHeader(conversation, prefix: "←", in: header)
        drawThreadPane(conversationID: id, in: body.inset(dx: 1), isActive: true)
      } else {
        drawList(in: rect, isActive: true)
      }
      return
    }
    let listWidth = min(52, max(32, rect.width * 34 / 100))
    let (left, rest) = rect.splitLeft(listWidth)
    let (divider, right) = rest.splitLeft(1)
    drawList(in: left, isActive: ui.pane == .list)
    for y in divider.y..<divider.maxY {
      canvas.put(Theme.Box.vertical, x: divider.x, y: y, style: Theme.border)
    }
    if let id = store.selectedConversationID, let conversation = store.conversation(id) {
      let (header, body) = right.splitTop(2)
      drawConversationHeader(conversation, prefix: nil, in: header)
      drawThreadPane(conversationID: id, in: body.inset(dx: 1), isActive: ui.pane == .thread)
    } else {
      drawCentered(["Aucun fil ouvert", "Entrée pour ouvrir · / pour chercher"], in: right)
    }
  }

  func drawList(in rect: Rect, isActive: Bool) {
    let (header, body) = rect.splitTop(3)
    // Les portées, en onglets.
    var x = header.x + 1
    for scope in InboxScope.allCases {
      let selected = store.scope == scope
      let count: Int = switch scope {
      case .requests: store.conversations(in: .requests).count
      case .reminders: store.conversations(in: .reminders).count
      default: 0
      }
      let label = count > 0 ? "\(scope.labelFR) \(count)" : scope.labelFR
      x = canvas.put(label, x: x, y: header.y, style: selected ? Theme.accentStrong.with(.underline) : Theme.muted, clip: header)
      x = canvas.put("  ", x: x, y: header.y, style: .plain, clip: header)
    }
    var filter = store.filter.labelFR
    if let network = store.networkFilter { filter += " · \(network.labelFR)" }
    if store.isIncognito { filter += " · incognito" }
    canvas.put(filter, x: header.x + 1, y: header.y + 1, maxWidth: header.width - 2, style: Theme.muted, clip: header)
    canvas.put(String(repeating: Theme.Box.horizontal, count: header.width), x: header.x, y: header.y + 2, style: Theme.border, clip: header)

    let list = store.visibleConversations
    guard !list.isEmpty else {
      drawCentered([emptyListTitle(), "s portée · f filtre · r réseau"], in: body)
      return
    }
    // La sélection survit au réordonnancement ; si sa ligne a disparu, elle
    // glisse sur la voisine.
    var selectedIndex = list.firstIndex(where: { $0.id == ui.listSelectionID }) ?? min(ui.listLastIndex, list.count - 1)
    selectedIndex = max(0, selectedIndex)
    if ui.listSelectionID != list[selectedIndex].id {
      ui.listSelectionID = list[selectedIndex].id
    }
    ui.listLastIndex = selectedIndex
    ui.listCount = list.count
    let rowHeight = 2
    let visibleRows = max(1, body.height / rowHeight)
    ui.listPageSize = visibleRows
    if selectedIndex < ui.listTop { ui.listTop = selectedIndex }
    if selectedIndex >= ui.listTop + visibleRows { ui.listTop = selectedIndex - visibleRows + 1 }
    ui.listTop = max(0, min(ui.listTop, list.count - visibleRows))
    ui.listRowFrames = []

    for row in 0..<visibleRows {
      let index = ui.listTop + row
      guard index < list.count else { break }
      let frame = Rect(x: body.x, y: body.y + row * rowHeight, width: body.width, height: rowHeight)
      ui.listRowFrames.append((frame, list[index].id))
      drawRow(list[index], in: frame, isSelected: index == selectedIndex, isActive: isActive)
    }
    // Un indicateur de défilement discret, à droite.
    if list.count > visibleRows {
      let track = body.height
      let thumb = max(1, track * visibleRows / list.count)
      let offset = (track - thumb) * ui.listTop / max(1, list.count - visibleRows)
      for i in 0..<thumb {
        canvas.put("▐", x: body.maxX - 1, y: body.y + offset + i, style: Theme.border)
      }
    }
  }

  private func emptyListTitle() -> String {
    switch store.scope {
    case .inbox: store.filter == .all ? "Inbox vide." : "Rien pour ce filtre."
    case .archive: "Rien d’archivé."
    case .reminders: "Aucun rappel en attente."
    case .requests: "Aucune demande."
    }
  }

  func drawRow(_ conversation: Conversation, in frame: Rect, isSelected: Bool, isActive: Bool) {
    let id = conversation.id
    let unread = conversation.unreadCount > 0
    let marker = isSelected ? "▌" : " "
    let markerStyle = isActive ? Theme.selectionMarker : Theme.inactiveMarker
    let right = frame.maxX - 2
    canvas.put(marker, x: frame.x, y: frame.y, style: markerStyle)
    canvas.put(marker, x: frame.x, y: frame.y + 1, style: markerStyle)

    // Ligne 1 : pastille, titre, heure.
    let stamp = Dates.listStamp(conversation.lastMessageAt)
    let stampX = right - CellWidth.of(stamp)
    canvas.put(unread ? "●" : " ", x: frame.x + 2, y: frame.y, style: store.isMuted(id) ? Theme.muted : Theme.accent)
    var titleStyle = unread ? Theme.strong : Theme.text
    if isSelected, isActive { titleStyle = titleStyle.with(.bold) }
    canvas.put(conversation.title, x: frame.x + 4, y: frame.y, maxWidth: stampX - frame.x - 5, style: titleStyle)
    canvas.put(stamp, x: stampX, y: frame.y, style: unread ? Theme.accent : Theme.muted)

    // Ligne 2 : réseau, aperçu, pastilles.
    var trailing = ""
    if store.isPinned(id) { trailing += " ↑" }
    if store.isMuted(id) { trailing += " ∅" }
    if store.reminder(id) != nil { trailing += " ⏲" }
    if conversation.unreadCount > 0 { trailing += " \(conversation.unreadCount)" }
    let trailingWidth = CellWidth.of(trailing)
    var x = frame.x + 4
    let tag = Theme.networkTag(conversation.network)
    x = canvas.put(tag, x: x, y: frame.y + 1, style: Theme.network(conversation.network).with(.dim))
    x = canvas.put(" ", x: x, y: frame.y + 1, style: .plain)
    let room = max(0, right - trailingWidth - x - 1)
    let draft = store.draftText(id).trimmingCharacters(in: .whitespacesAndNewlines)
    if let typing = store.typingLabel(id) {
      canvas.put(typing, x: x, y: frame.y + 1, maxWidth: room, style: Theme.accent.with(.italic))
    } else if !draft.isEmpty, store.selectedConversationID != id || ui.mode != .inbox {
      x = canvas.put("Brouillon : ", x: x, y: frame.y + 1, style: Theme.warning)
      canvas.put(TextLayout.singleLine(draft), x: x, y: frame.y + 1, maxWidth: max(0, right - trailingWidth - x - 1), style: Theme.muted)
    } else {
      var preview = TextLayout.singleLine(conversation.preview)
      if conversation.lastMessageIsFromMe { preview = "Vous : " + preview }
      if store.isRequest(id) { preview = "Demande · " + preview }
      canvas.put(preview, x: x, y: frame.y + 1, maxWidth: room, style: unread ? Theme.text : Theme.muted)
    }
    canvas.put(trailing, x: right - trailingWidth, y: frame.y + 1, style: unread ? Theme.accentStrong : Theme.muted)
  }

  // MARK: - Fil

  /// Le fil et son composer, dans un rectangle.
  func drawThreadPane(conversationID: String, in rect: Rect, isActive: Bool) {
    let composerHeight = composerRows(conversationID: conversationID, width: rect.width - 2)
    let (threadRect, composerRect) = rect.splitBottom(composerHeight)
    drawThread(conversationID: conversationID, in: threadRect, isActive: isActive && !ui.isComposing)
    drawComposer(conversationID: conversationID, in: composerRect, isActive: isActive)
  }

  func drawThread(conversationID: String, in rect: Rect, isActive: Bool) {
    guard rect.height > 0 else { return }
    // Une colonne pour le curseur de message, une pour respirer.
    let contentX = rect.x + 2
    let contentWidth = max(10, rect.width - 3)
    let lines = threadLines(conversationID: conversationID, width: contentWidth)
    var viewport = ui.viewports[conversationID] ?? UIState.ThreadViewport()

    // Un message arrive pendant qu'on lit plus haut : la vue ne bouge pas.
    let lastID = store.visibleMessages(conversationID).last?.id
    if viewport.scrollFromBottom > 0, viewport.lastMessageID != nil, viewport.lastMessageID != lastID, lines.count > viewport.lastTotalLines {
      viewport.scrollFromBottom += lines.count - viewport.lastTotalLines
    }
    viewport.lastTotalLines = lines.count
    viewport.lastMessageID = lastID

    let maxScroll = max(0, lines.count - rect.height)
    // Le curseur toujours visible.
    if let cursor = viewport.cursorMessageID {
      if let first = lines.firstIndex(where: { $0.messageID == cursor }),
         let last = lines.lastIndex(where: { $0.messageID == cursor }) {
        let bottomIndex = lines.count - viewport.scrollFromBottom // exclusif
        let topIndex = bottomIndex - rect.height
        if last >= bottomIndex { viewport.scrollFromBottom = max(0, lines.count - last - 1) }
        else if first < topIndex { viewport.scrollFromBottom = lines.count - first - rect.height }
      } else {
        viewport.cursorMessageID = nil
      }
    }
    viewport.scrollFromBottom = max(0, min(viewport.scrollFromBottom, maxScroll))
    ui.viewports[conversationID] = viewport
    ui.threadPageSize = rect.height

    // Tout en haut : on demande la page d'avant.
    if viewport.scrollFromBottom >= maxScroll {
      requestOlder(conversationID)
    }

    let end = lines.count - viewport.scrollFromBottom
    let start = max(0, end - rect.height)
    // Collé en bas : le fil court s'aligne en bas, comme une messagerie.
    let topPadding = rect.height - (end - start)
    ui.threadLineFrames = []
    for (offset, index) in (start..<end).enumerated() {
      let y = rect.y + topPadding + offset
      let line = lines[index]
      let isCursor = line.messageID != nil && line.messageID == viewport.cursorMessageID
      if isCursor {
        canvas.put("▌", x: rect.x, y: y, style: isActive ? Theme.selectionMarker : Theme.inactiveMarker)
      }
      if let messageID = line.messageID { ui.threadLineFrames.append((y, messageID)) }
      drawThreadLine(line, x: contentX, y: y, width: contentWidth, clip: rect)
    }

    if viewport.scrollFromBottom > 0 {
      let hint = " ↓ \(viewport.scrollFromBottom) lignes · G "
      canvas.put(hint, x: rect.maxX - CellWidth.of(hint) - 1, y: rect.maxY - 1, style: Theme.accent.with(.reverse))
    }
    if let seen = store.seenByLabel(conversationID), viewport.scrollFromBottom == 0, topPadding > 0 {
      canvas.put(seen, x: rect.maxX - CellWidth.of(seen) - 1, y: rect.maxY - 1, maxWidth: rect.width, style: Theme.muted)
    }
  }

  private func drawThreadLine(_ line: ThreadLine, x: Int, y: Int, width: Int, clip: Rect) {
    let startX: Int = switch line.alignment {
    case .leading: x
    case .trailing: x + max(0, width - line.blockWidth)
    case .center: x + max(0, (width - line.width) / 2)
    }
    switch line.content {
    case .blank:
      break
    case .spans(let spans):
      var column = startX
      for span in spans {
        var style = span.style
        if let link = span.link { style.link = canvas.link(link) }
        column = canvas.put(span.text, x: column, y: y, style: style, clip: clip)
      }
    case .image(let id, let row, let columns):
      for column in 0..<columns {
        canvas.setCell(KittyGraphics.placeholder(id: id, row: row, column: column), x: startX + column, y: y, clip: clip)
      }
    }
  }

  private func requestOlder(_ conversationID: String) {
    guard !store.isLoadingOlder, !ui.olderRequested.contains(conversationID) else { return }
    ui.olderRequested.insert(conversationID)
    Task { @MainActor [weak self] in
      await self?.store.loadOlder(conversationID: conversationID)
      // Une seconde de répit avant de pouvoir redemander : le défilement
      // continu ne doit pas enchaîner les requêtes.
      try? await Task.sleep(for: .seconds(1))
      self?.ui.olderRequested.remove(conversationID)
    }
  }

  // MARK: - Composer

  func composerRows(conversationID: String, width: Int) -> Int {
    let text = composerText(conversationID)
    let lines = min(8, max(1, TextLayout.wrap(text, width: max(1, width)).count))
    let context = composerContext(conversationID) != nil ? 1 : 0
    return 1 + context + lines
  }

  /// Le texte à montrer : ce que le composer tient s'il écrit à ce fil, le
  /// brouillon du magasin sinon.
  func composerText(_ conversationID: String) -> String {
    syncComposer(conversationID)
    if ui.composerConversationID == conversationID { return ui.composer.text }
    return store.draftText(conversationID)
  }

  /// Adopte ce que le magasin a changé de lui-même (envoi, correction, annulation).
  func syncComposer(_ conversationID: String) {
    guard ui.composerConversationID == conversationID else { return }
    let stored = store.draftText(conversationID)
    if stored != ui.composerSynced {
      ui.composerSynced = stored
      if stored != ui.composer.text { ui.composer.setText(stored) }
    }
  }

  func composerContext(_ conversationID: String) -> (String, Style)? {
    if let editing = store.editingMessage(conversationID) {
      return ("Correction de « \(TextLayout.singleLine(editing.text)) » · Échap pour renoncer", Theme.warning)
    }
    if let reply = store.replyTarget(conversationID) {
      let sender = reply.isFromMe ? "vous" : (reply.displayedSenderName ?? store.conversation(conversationID)?.title ?? "")
      return ("Réponse à \(sender) : \(TextLayout.singleLine(reply.sidebarPreviewText))", Theme.accent)
    }
    let files = store.attachments(conversationID)
    if !files.isEmpty {
      let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
      return ("📎 \(names) · ^X pour retirer", Theme.accent)
    }
    return nil
  }

  func drawComposer(conversationID: String, in rect: Rect, isActive: Bool) {
    guard rect.height > 0 else { return }
    let composing = ui.isComposing && isActive && ui.composerConversationID == conversationID
    canvas.put(String(repeating: Theme.Box.horizontal, count: rect.width), x: rect.x, y: rect.y, style: composing ? Theme.accent : Theme.border)
    var y = rect.y + 1
    if let (context, style) = composerContext(conversationID) {
      canvas.put(context, x: rect.x + 1, y: y, maxWidth: rect.width - 2, style: style)
      y += 1
    }
    let width = max(1, rect.width - 2)
    ui.composerWidth = width
    let text = composerText(conversationID)
    if text.isEmpty && !composing {
      let network = store.sendingNetwork(conversationID)?.labelFR
      let placeholder = "i pour écrire" + (network.map { " · via \($0)" } ?? "")
      canvas.put(placeholder, x: rect.x + 1, y: y, maxWidth: width, style: Theme.muted)
      return
    }
    let editor = composing ? ui.composer : LineEditor(text, allowsNewlines: true)
    let position = editor.cursorPosition(width: width)
    let visible = rect.maxY - y
    // Le curseur reste dans la fenêtre du composer.
    let firstLine = max(0, min(position.row - visible + 1, position.lines.count - visible))
    for (offset, line) in position.lines.dropFirst(firstLine).prefix(visible).enumerated() {
      canvas.put(line.text, x: rect.x + 1, y: y + offset, style: .plain, clip: rect)
    }
    if composing {
      let cursorX = min(rect.maxX - 1, rect.x + 1 + position.column)
      canvas.cursor = (cursorX, y + position.row - firstLine)
      canvas.cursorShape = .bar
    }
    if store.isSending(conversationID) {
      canvas.put(" envoi… ", x: rect.maxX - 9, y: rect.y, style: Theme.warning)
    }
  }

  // MARK: - Barre d'état

  func drawStatusBar(in rect: Rect) {
    let y = rect.y
    var x = rect.x
    let modeLabel = ui.mode == .focus ? " FOCUS " : " INBOX "
    x = canvas.put(modeLabel, x: x, y: y, style: Style(foreground: .black, background: ui.mode == .focus ? .blue : .magenta, attributes: .bold))
    if ui.isComposing {
      x = canvas.put(" ÉCRIRE ", x: x, y: y, style: Style(foreground: .black, background: .green, attributes: .bold))
    }
    x += 1

    // À droite : l'état du Relais et les compteurs.
    var right: [(String, Style)] = []
    if store.isDemo { right.append(("démo", Theme.warning)) }
    if store.isIncognito { right.append(("incognito", Theme.agent)) }
    if CorrespondanceHome.isTrial, !store.isDemo, CorrespondanceHome.name != "terminal" {
      right.append(("essai \(CorrespondanceHome.name ?? "")", Theme.warning))
    }
    let unread = store.unreadCount(for: nil)
    if unread > 0 { right.append(("\(unread) non lus", Theme.accent)) }
    if store.syncError != nil {
      right.append(("● hors ligne", Theme.danger))
    } else if !store.isDemo {
      right.append(("●", Theme.success))
    }
    right.append(("? aide", Theme.muted))
    let rightText = right.map(\.0).joined(separator: "  ")
    var rx = rect.maxX - CellWidth.of(rightText) - 1
    let rightStart = rx
    for (index, item) in right.enumerated() {
      if index > 0 { rx = canvas.put("  ", x: rx, y: y, style: .plain) }
      rx = canvas.put(item.0, x: rx, y: y, style: item.1)
    }

    let room = max(0, rightStart - x - 2)
    if let toast = ui.toast, toast.until > Date() {
      canvas.put(toast.text, x: x, y: y, maxWidth: room, style: toast.isError ? Theme.danger : Theme.success)
    } else if let error = store.syncError ?? store.connectionError {
      canvas.put(error, x: x, y: y, maxWidth: room, style: Theme.danger)
    } else {
      canvas.put(contextualHints(), x: x, y: y, maxWidth: room, style: Theme.muted)
    }
  }

  private func contextualHints() -> String {
    if ui.isComposing {
      return "Entrée envoyer · ⇧/⌥Entrée ligne · Échap sortir · ^O joindre"
    }
    switch (ui.mode, ui.pane) {
    case (.focus, _):
      return "n suivante · p précédente · a archiver · i écrire · j/k messages · z rappel"
    case (.inbox, .list):
      return "j/k naviguer · Entrée ouvrir · a archiver · P épingler · z rappel · / chercher"
    case (.inbox, .thread):
      return "j/k messages · i écrire · r répondre · + réagir · e corriger · Échap liste"
    }
  }
}
