import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

@MainActor
extension TUIApp {
  // MARK: - Cadre

  /// Un panneau centré, bordé, vidé : rend l'intérieur.
  @discardableResult
  func drawPanel(title: String, width: Int, height: Int, in bounds: Rect, top: Int? = nil) -> Rect {
    let w = min(width, bounds.width - 2)
    let h = min(height, bounds.height - 2)
    let x = bounds.x + (bounds.width - w) / 2
    let y = top.map { min($0, bounds.height - h - 1) } ?? bounds.y + (bounds.height - h) / 2
    let frame = Rect(x: x, y: y, width: w, height: h)
    canvas.fill(frame, style: .plain)
    let horizontal = String(repeating: Theme.Box.horizontal, count: max(0, w - 2))
    canvas.put(Theme.Box.topLeft + horizontal + Theme.Box.topRight, x: x, y: y, style: Theme.border)
    canvas.put(Theme.Box.bottomLeft + horizontal + Theme.Box.bottomRight, x: x, y: frame.maxY - 1, style: Theme.border)
    for row in (y + 1)..<(frame.maxY - 1) {
      canvas.put(Theme.Box.vertical, x: x, y: row, style: Theme.border)
      canvas.put(Theme.Box.vertical, x: frame.maxX - 1, y: row, style: Theme.border)
    }
    canvas.put(" \(title) ", x: x + 2, y: y, maxWidth: w - 4, style: Theme.accentStrong)
    return frame.inset(dx: 2, dy: 1)
  }

  /// Une liste avec sélection, dans un rectangle ; défile pour garder la sélection visible.
  func drawMenu(_ items: [(String, Style)], selected: Int, in rect: Rect) {
    guard rect.height > 0 else { return }
    let top = max(0, min(selected - rect.height + 1, items.count - rect.height))
    for (row, index) in (top..<min(items.count, top + rect.height)).enumerated() {
      let isSelected = index == selected
      canvas.put(isSelected ? "▌" : " ", x: rect.x, y: rect.y + row, style: Theme.selectionMarker)
      var style = items[index].1
      if isSelected { style = style.with(.bold) }
      canvas.put(items[index].0, x: rect.x + 2, y: rect.y + row, maxWidth: rect.width - 2, style: style)
    }
  }

  func drawField(_ label: String, editor: LineEditor, x: Int, y: Int, width: Int, isActive: Bool, secure: Bool = false, labelWidth: Int = 20) {
    canvas.put(label, x: x, y: y, maxWidth: labelWidth - 1, style: isActive ? Theme.accentStrong : Theme.muted)
    let fieldX = x + labelWidth
    let fieldWidth = max(4, width - labelWidth)
    let shown = secure ? String(repeating: "•", count: editor.characters.count) : editor.text
    // Un champ d'une ligne défile pour garder le curseur en vue.
    let cursorColumn = CellWidth.of(String((secure ? Array(shown) : editor.characters).prefix(editor.cursor)))
    let scroll = max(0, cursorColumn - fieldWidth + 1)
    var visible = ""
    var used = 0
    var skipped = 0
    for character in shown {
      let w = CellWidth.of(character)
      if skipped < scroll {
        skipped += w
        continue
      }
      if used + w > fieldWidth { break }
      visible.append(character)
      used += w
    }
    canvas.fill(Rect(x: fieldX, y: y, width: fieldWidth, height: 1), style: Style(attributes: .underline).foreground(isActive ? .default : .brightBlack))
    canvas.put(visible, x: fieldX, y: y, style: Style(attributes: .underline))
    if isActive {
      canvas.cursor = (fieldX + cursorColumn - scroll, y)
      canvas.cursorShape = .bar
    }
  }

  // MARK: - Surimpressions

  func drawOverlay(in bounds: Rect) {
    guard let overlay = ui.overlay else { return }
    switch overlay {
    case .help:
      drawHelp(in: bounds)

    case .search(let state):
      let inner = drawPanel(title: "Chercher", width: 90, height: min(bounds.height - 2, 26), in: bounds, top: 2)
      drawField("", editor: state.editor, x: inner.x, y: inner.y, width: inner.width, isActive: true, labelWidth: 0)
      canvas.put(String(repeating: Theme.Box.horizontal, count: inner.width), x: inner.x, y: inner.y + 1, style: Theme.border)
      let listRect = Rect(x: inner.x, y: inner.y + 2, width: inner.width, height: inner.height - 2)
      if state.results.isEmpty {
        canvas.put(state.query.isEmpty ? "Un nom, un mot d’un message…" : "Rien trouvé.", x: listRect.x, y: listRect.y, style: Theme.muted)
      } else {
        let items = state.results.map { result -> (String, Style) in
          ("\(result.title)  ·  \(Theme.networkTag(result.network))  ·  \(TextLayout.singleLine(result.excerpt))", .plain)
        }
        drawMenu(items, selected: state.index, in: listRect)
      }

    case .reactions(_, _, let index):
      let reactions = RelayStore.quickReactions
      let inner = drawPanel(title: "Réagir", width: 6 * reactions.count + 6, height: 5, in: bounds)
      var x = inner.x
      for (i, emoji) in reactions.enumerated() {
        let selected = i == index
        x = canvas.put("\(i + 1)", x: x, y: inner.y, style: selected ? Theme.accentStrong : Theme.muted)
        x = canvas.put(" \(emoji) ", x: x, y: inner.y, style: selected ? Style(attributes: .reverse) : .plain)
        x += 1
      }
      canvas.put("1–6 ou ←/→ puis Entrée · Échap", x: inner.x, y: inner.y + 2, maxWidth: inner.width, style: Theme.muted)

    case .reminder(let conversationID, let index):
      let items = reminderItems(conversationID)
      let inner = drawPanel(title: "Rappel", width: 48, height: items.count + 4, in: bounds)
      drawMenu(items.map { ($0.title, $0.date == nil ? Theme.danger : Style.plain) }, selected: index, in: Rect(x: inner.x, y: inner.y, width: inner.width, height: items.count))
      canvas.put("Revient dans la file si personne n’a répondu", x: inner.x, y: inner.maxY - 1, maxWidth: inner.width, style: Theme.muted)

    case .forward(let state):
      let targets = store.forwardTargets(state.editor.text)
      let inner = drawPanel(title: "Transférer à…", width: 70, height: min(bounds.height - 2, 22), in: bounds, top: 3)
      drawField("", editor: state.editor, x: inner.x, y: inner.y, width: inner.width, isActive: true, labelWidth: 0)
      canvas.put(String(repeating: Theme.Box.horizontal, count: inner.width), x: inner.x, y: inner.y + 1, style: Theme.border)
      drawMenu(targets.map { ("\($0.title)  ·  \(Theme.networkTag($0.network))", .plain) }, selected: min(state.index, max(0, targets.count - 1)), in: Rect(x: inner.x, y: inner.y + 2, width: inner.width, height: inner.height - 2))

    case .confirm(let state):
      let lines = TextLayout.wrap(state.detail, width: 50)
      let inner = drawPanel(title: state.title, width: 56, height: lines.count + 5, in: bounds)
      for (i, line) in lines.enumerated() {
        canvas.put(line.text, x: inner.x, y: inner.y + i, style: .plain)
      }
      canvas.put("y confirmer · n ou Échap annuler", x: inner.x, y: inner.maxY - 1, style: Theme.accent)

    case .attach(_, let editor, let error):
      let inner = drawPanel(title: "Joindre un fichier", width: 80, height: 6, in: bounds)
      drawField("Chemin", editor: editor, x: inner.x, y: inner.y, width: inner.width, isActive: true)
      if let error {
        canvas.put(error, x: inner.x, y: inner.y + 2, maxWidth: inner.width, style: Theme.danger)
      } else {
        canvas.put("Tab complète · Entrée joint · glisser un fichier dans le terminal marche aussi", x: inner.x, y: inner.y + 2, maxWidth: inner.width, style: Theme.muted)
      }

    case .poll(let conversationID, let messageID, let index):
      guard let poll = store.visibleMessages(conversationID).first(where: { $0.id == messageID })?.poll else { return }
      let inner = drawPanel(title: TextLayout.truncate(poll.question, to: 50), width: 60, height: poll.answers.count + 4, in: bounds)
      let items = poll.answers.map { answer -> (String, Style) in
        (poll.myAnswerIDs.contains(answer.id) ? "● \(answer.text)" : "○ \(answer.text)", .plain)
      }
      drawMenu(items, selected: index, in: Rect(x: inner.x, y: inner.y, width: inner.width, height: poll.answers.count))
      canvas.put("Entrée vote (ou retire son vote)", x: inner.x, y: inner.maxY - 1, style: Theme.muted)

    case .filters(let index):
      let items = filterItems()
      let inner = drawPanel(title: "Filtrer", width: 40, height: items.count + 3, in: bounds)
      drawMenu(items.map { ($0.label, $0.isCurrent ? Theme.accent : Style.plain) }, selected: index, in: inner)
    }
  }

  struct ReminderItem {
    var title: String
    var date: Date?
  }

  func reminderItems(_ conversationID: String) -> [ReminderItem] {
    var items = ConversationReminder.suggestions().map { suggestion in
      ReminderItem(title: "\(suggestion.title) — \(Dates.moment(suggestion.date))", date: suggestion.date)
    }
    if store.reminder(conversationID) != nil {
      items.append(ReminderItem(title: "Retirer le rappel", date: nil))
    }
    return items
  }

  struct FilterItem {
    var label: String
    var isCurrent: Bool
    var apply: @MainActor (RelayStore) -> Void
  }

  func filterItems() -> [FilterItem] {
    var items = ConversationFilter.allCases.map { filter in
      FilterItem(label: filter.labelFR, isCurrent: store.filter == filter) { $0.filter = filter }
    }
    items.append(FilterItem(label: "Tous les réseaux", isCurrent: store.networkFilter == nil) { $0.networkFilter = nil })
    for network in store.networksInUse {
      items.append(FilterItem(label: "Réseau : \(network.labelFR)", isCurrent: store.networkFilter == network) { $0.networkFilter = network })
    }
    return items
  }

  // MARK: - Aide

  func drawHelp(in bounds: Rect) {
    let sections: [(String, [(String, String)])] = [
      ("Partout", [
        ("1 / 2", "Focus / Inbox"), ("/", "chercher"), ("?", "cette aide"), ("q", "quitter"),
        ("I", "incognito (lire sans accusé)"), ("R", "recharger depuis le Relais"), ("^L", "redessiner"), ("^Z", "suspendre"),
      ]),
      ("Focus", [
        ("n  →", "conversation suivante"), ("p  ←", "précédente"), ("a", "archiver et avancer"),
      ]),
      ("Liste (Inbox)", [
        ("j k  ↑ ↓", "naviguer"), ("Entrée  l", "ouvrir le fil"), ("s / S", "portée suivante / précédente"),
        ("f", "filtres et réseaux"), ("A", "archiver tout ce qui est lu"), ("x / X", "accepter / refuser une demande"),
        ("N", "note à soi"),
      ]),
      ("Sur une conversation", [
        ("a", "archiver / désarchiver"), ("P", "épingler"), ("m", "muet"), ("z", "rappel"), ("M", "marquer lu"),
      ]),
      ("Fil", [
        ("j k", "message suivant / précédent"), ("^D ^U", "demi-page"), ("g / G", "début / fin"),
        ("i  Entrée", "écrire"), ("r", "répondre"), ("e", "corriger"), ("+", "réagir"), ("F", "transférer"),
        ("y", "copier le texte"), ("o  clic", "ouvrir la pièce jointe ou le lien"), ("D", "supprimer pour tous"), ("H", "masquer"),
        ("u", "annuler l’envoi"), ("V", "voter"), ("S E X", "proposition de cc : envoyer, modifier, ignorer"),
        ("Échap  h", "retour à la liste"),
      ]),
      ("Composer", [
        ("Entrée", "envoyer"), ("⇧Entrée ⌥Entrée ^J", "nouvelle ligne"), ("↑ (vide)", "corriger mon dernier message"),
        ("^O", "joindre un fichier"), ("^X", "retirer les pièces jointes"), ("Échap", "sortir (le brouillon reste)"),
        ("^W ^U ^K", "effacer mot / début / fin"), ("⌥← ⌥→", "mot par mot"),
      ]),
    ]
    let columnWidth = 50
    let columns = min(3, max(1, (bounds.width - 6) / (columnWidth + 2)))
    var heights = [0, 0, 0]
    var placement: [(Int, Int, (String, [(String, String)]))] = []
    for section in sections {
      let column = (0..<columns).min(by: { heights[$0] < heights[$1] }) ?? 0
      placement.append((column, heights[column], section))
      heights[column] += section.1.count + 2
    }
    let height = (heights.max() ?? 0) + 2
    let inner = drawPanel(title: "Raccourcis", width: (columnWidth + 2) * columns + 4, height: height + 1, in: bounds)
    for (column, row, section) in placement {
      let x = inner.x + column * (columnWidth + 2)
      var y = inner.y + row
      guard y < inner.maxY else { continue }
      canvas.put(section.0, x: x, y: y, style: Theme.accentStrong, clip: inner)
      y += 1
      for (keys, label) in section.1 where y < inner.maxY {
        canvas.put(keys, x: x, y: y, maxWidth: 18, style: Theme.strong, clip: inner)
        canvas.put(label, x: x + 19, y: y, maxWidth: columnWidth - 20, style: .plain, clip: inner)
        y += 1
      }
    }
  }

  // MARK: - Connexion

  func drawLogin(in bounds: Rect) {
    if !ui.login.didPrefill {
      ui.login.didPrefill = true
      ui.login.homeserver.setText(store.rememberedHomeserver)
    }
    let inner = drawPanel(title: "Correspondance · terminal", width: 76, height: 21, in: bounds)
    var y = inner.y
    canvas.put("Connecte ce terminal à ton Relais.", x: inner.x, y: y, style: Theme.strong)
    y += 2

    // Le chemin sans rien taper : la session de l'app de cette machine.
    let linkSelected = ui.login.field == 0
    let linkTitle: String = switch ui.login.link {
    case .idle: "Utiliser la session de l’app de cette machine"
    case .working: "Connexion depuis la session de l’app…"
    case .needsPassword(_, let user): "Le Relais demande une fois le mot de passe de \(user)"
    }
    canvas.put(linkSelected ? "▌" : " ", x: inner.x, y: y, style: Theme.selectionMarker)
    canvas.put(linkTitle, x: inner.x + 2, y: y, maxWidth: inner.width - 2, style: linkSelected ? Theme.accentStrong : Theme.text)
    y += 1
    if case .needsPassword = ui.login.link {
      drawField("  Mot de passe", editor: ui.login.linkPassword, x: inner.x, y: y, width: inner.width, isActive: linkSelected, secure: true)
    } else {
      canvas.put("  Un nouvel appareil, sans code d’appairage — l’app reste ouverte.", x: inner.x, y: y, maxWidth: inner.width, style: Theme.muted)
    }
    y += 2
    canvas.put("— ou —", x: inner.x + (inner.width - 6) / 2, y: y, style: Theme.muted)
    y += 2
    drawField("Code d’appairage", editor: ui.login.code, x: inner.x, y: y, width: inner.width, isActive: ui.login.field == 1)
    y += 2
    drawField("Adresse du Relais", editor: ui.login.homeserver, x: inner.x, y: y, width: inner.width, isActive: ui.login.field == 2)
    y += 1
    drawField("Utilisateur", editor: ui.login.user, x: inner.x, y: y, width: inner.width, isActive: ui.login.field == 3)
    y += 1
    drawField("Mot de passe", editor: ui.login.password, x: inner.x, y: y, width: inner.width, isActive: ui.login.field == 4, secure: true)
    y += 2
    if let error = store.connectionError {
      for line in TextLayout.wrap(error, width: inner.width).prefix(3) {
        canvas.put(line.text, x: inner.x, y: y, style: Theme.danger)
        y += 1
      }
    }
    canvas.put("↑↓/Tab choisir · Entrée se connecter · ^C quitter", x: inner.x, y: inner.maxY - 1, maxWidth: inner.width, style: Theme.muted)
  }
}
