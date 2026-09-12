import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

/// Une ligne du fil, prête à poser.
struct ThreadLine {
  enum Content {
    case spans([Span])
    /// Une rangée de placeholders d'image.
    case image(id: UInt32, row: Int, columns: Int)
    case blank
  }

  enum Alignment { case leading, trailing, center }

  struct Span {
    var text: String
    var style: Style
    var link: String?
    init(_ text: String, _ style: Style = .plain, link: String? = nil) {
      self.text = text
      self.style = style
      self.link = link
    }
  }

  var content: Content
  var alignment: Alignment = .leading
  /// Largeur du bloc (le message entier) : les lignes d'un même message
  /// s'alignent sur son bord, pas chacune sur le bord du panneau.
  var blockWidth: Int = 0
  var width: Int = 0
  var messageID: String?

  static func text(_ spans: [Span], alignment: Alignment = .leading, messageID: String? = nil) -> ThreadLine {
    let width = spans.reduce(0) { $0 + CellWidth.of($1.text) }
    return ThreadLine(content: .spans(spans), alignment: alignment, blockWidth: width, width: width, messageID: messageID)
  }
}

/// Les lignes déjà calculées, par groupe de messages et par largeur.
///
/// Un fil de mille messages se met en page une fois ; ensuite, une image de
/// l'écran ne recalcule que le groupe qui a changé (un message arrivé, une
/// réaction). La clé contient les messages eux-mêmes : toute modification
/// d'un message change la clé, sans compteur de version à tenir.
struct ThreadLayoutCache {
  struct Key: Hashable {
    let groupID: String
    let messages: [ChatMessage]
    let sender: String?
    let separator: Date?
    let origin: MessageNetwork?
    let width: Int
    let imageRevision: Int
    let undoable: Set<String>
  }

  private var entries: [Key: [ThreadLine]] = [:]
  private(set) var imageRevision = 0

  mutating func lines(for key: Key, build: () -> [ThreadLine]) -> [ThreadLine] {
    if let cached = entries[key] { return cached }
    if entries.count > 4000 { entries.removeAll(keepingCapacity: true) }
    let built = build()
    entries[key] = built
    return built
  }

  mutating func invalidateImages() {
    imageRevision += 1
  }

  mutating func removeAll() { entries.removeAll() }
}

@MainActor
extension TUIApp {
  /// Toutes les lignes d'un fil pour une largeur donnée, du plus ancien au plus récent.
  func threadLines(conversationID: String, width: Int) -> [ThreadLine] {
    let groups = store.groups(conversationID)
    let conversation = store.conversation(conversationID)
    var lines: [ThreadLine] = []
    if store.isLoadingOlder {
      lines.append(.text([.init("Chargement de l’historique…", Theme.muted)], alignment: .center))
    }
    let undoable = Set(groups.flatMap { $0.messages.filter { store.canUndoSend($0.id) }.map(\.id) })
    for group in groups {
      let key = ThreadLayoutCache.Key(
        groupID: group.id,
        messages: group.messages,
        sender: group.senderLabel,
        separator: group.timeSeparator,
        origin: group.networkOrigin,
        width: width,
        imageRevision: images.isEnabled ? threadCache.imageRevision : -1,
        undoable: undoable.intersection(group.messages.map(\.id))
      )
      lines += threadCache.lines(for: key) {
        layoutGroup(group, width: width, isGroupChat: conversation?.isGroup ?? false, undoable: key.undoable)
      }
    }
    return lines
  }

  private func layoutGroup(_ group: MessageGroup, width: Int, isGroupChat: Bool, undoable: Set<String>) -> [ThreadLine] {
    var lines: [ThreadLine] = []
    let bubble = max(12, min(width, Int(Double(width) * 0.8)))
    let mine = group.isFromMe
    let alignment: ThreadLine.Alignment = mine ? .trailing : .leading

    if let separator = group.timeSeparator {
      lines.append(.blank())
      let label = " \(Dates.separator(separator)) "
      let side = max(0, (width - CellWidth.of(label)) / 2)
      let rule = String(repeating: "─", count: min(side, 12))
      lines.append(.text([.init(rule, Theme.border), .init(label, Theme.muted), .init(rule, Theme.border)], alignment: .center))
    }
    lines.append(.blank())

    if let sender = group.senderLabel, !mine {
      var spans: [ThreadLine.Span] = [.init(sender, Theme.sender(sender))]
      if let origin = group.networkOrigin {
        spans.append(.init(" · \(origin.labelFR)", Theme.network(origin).with(.dim)))
      }
      lines.append(.text(spans, alignment: alignment))
    } else if let origin = group.networkOrigin {
      lines.append(.text([.init(origin.labelFR, Theme.network(origin).with(.dim))], alignment: alignment))
    }

    for (index, message) in group.messages.enumerated() {
      let isLast = index == group.messages.count - 1
      var block = layoutMessage(message, bubble: bubble, width: width, isGroupChat: isGroupChat, isLastInGroup: isLast, undoable: undoable.contains(message.id))
      let blockWidth = block.map(\.width).max() ?? 0
      for i in block.indices {
        block[i].messageID = message.id
        if block[i].alignment != .center {
          block[i].alignment = alignment
          block[i].blockWidth = blockWidth
        }
      }
      lines += block
    }
    return lines
  }

  private func layoutMessage(_ message: ChatMessage, bubble: Int, width: Int, isGroupChat: Bool, isLastInGroup: Bool, undoable: Bool) -> [ThreadLine] {
    var lines: [ThreadLine] = []

    if let system = message.systemEventText {
      for line in TextLayout.wrap(system, width: max(10, width - 4)) {
        lines.append(.text([.init(line.text, Theme.muted.with(.italic))], alignment: .center))
      }
      return lines
    }

    if let proposal = message.agentProposal {
      let inner = max(10, bubble - 2)
      lines.append(.text([.init("┃ ", Theme.agent), .init("✦ \(proposal.agent) propose", Theme.agent.with(.bold))]))
      for line in TextLayout.wrap(proposal.text, width: inner) {
        lines.append(.text([.init("┃ ", Theme.agent), .init(line.text)]))
      }
      lines.append(.text([.init("┃ ", Theme.agent), .init("S envoyer · E modifier · X ignorer", Theme.muted)]))
      return lines
    }

    if let quote = message.replyTo, !quote.isEmpty {
      let text = TextLayout.singleLine("\(quote.senderName) : \(quote.text)")
      lines.append(.text([.init("↳ ", Theme.border), .init(TextLayout.truncate(text, to: bubble - 2), Theme.muted)]))
    }

    if message.isRetracted {
      lines.append(.text([.init("Message supprimé", Theme.muted.with(.italic))]))
    } else if !message.text.isEmpty {
      lines += textLines(message.text, width: bubble, style: message.isEmojiOnly ? .plain : .plain)
    }

    for attachment in message.attachments.map(AttachmentRepair.repaired) {
      lines += attachmentLines(attachment, bubble: bubble)
    }

    if let preview = message.linkPreview, let title = preview.title, !title.isEmpty {
      lines.append(.text([.init("↗ ", Theme.accent), .init(TextLayout.truncate(TextLayout.singleLine(title), to: bubble - 2), Theme.muted, link: preview.url)]))
    }

    if let poll = message.poll {
      lines += pollLines(poll, bubble: bubble)
    }

    if let aside = message.agentAside {
      lines.append(.text([.init(TextLayout.truncate(aside.footnoteFR, to: bubble), Theme.agent.with(.dim))]))
    }

    // La ligne des métadonnées : l'heure en fin de groupe, et tout ce qui
    // mérite d'être dit (réactions, correction, envoi en cours).
    var meta: [ThreadLine.Span] = []
    func add(_ text: String, _ style: Style) {
      if !meta.isEmpty { meta.append(.init(" · ", Theme.muted)) }
      meta.append(.init(text, style))
    }
    if !message.reactions.isEmpty {
      let reactions = message.reactions.map { $0.count > 1 ? "\($0.emoji)\($0.count)" : $0.emoji }.joined(separator: " ")
      meta.append(.init(reactions, message.reactions.contains(where: \.isMine) ? Theme.accent : .plain))
    }
    if isLastInGroup || message.isPending || message.editedAt != nil || !message.reactions.isEmpty {
      add(Dates.clock(message.sentAt), Theme.muted)
    }
    if message.editedAt != nil { add("modifié", Theme.muted) }
    if message.isPending { add(undoable ? "envoi différé" : "envoi…", Theme.warning) }
    if undoable { add("u annuler", Theme.accent) }
    if !meta.isEmpty { lines.append(.text(meta)) }
    return lines
  }

  /// Le texte d'un message, coupé à la largeur, avec son Markdown de pont
  /// (gras, italique, code, barré) et ses liens cliquables (OSC 8).
  private func textLines(_ raw: String, width: Int, style: Style) -> [ThreadLine] {
    let (text, runs) = styledRuns(raw, base: style)
    return TextLayout.wrap(text, width: width).map { line in
      guard !runs.isEmpty else { return .text([.init(line.text, style)]) }
      var spans: [ThreadLine.Span] = []
      var buffer = ""
      var current: (style: Style, link: String?) = (style, nil)
      var offset = line.startOffset
      var runIndex = 0
      for character in line.text {
        while runIndex < runs.count, runs[runIndex].range.upperBound <= offset { runIndex += 1 }
        var next: (style: Style, link: String?) = (style, nil)
        if runIndex < runs.count, runs[runIndex].range.contains(offset) {
          next = (runs[runIndex].style, runs[runIndex].link)
        }
        if (next.style != current.style || next.link != current.link), !buffer.isEmpty {
          spans.append(.init(buffer, current.style, link: current.link))
          buffer = ""
        }
        current = next
        buffer.append(character)
        offset += 1
      }
      if !buffer.isEmpty { spans.append(.init(buffer, current.style, link: current.link)) }
      return .text(spans)
    }
  }

  /// Le texte à montrer et ses tronçons stylés, en décalages de graphèmes, triés.
  private func styledRuns(_ raw: String, base: Style) -> (String, [(range: Range<Int>, style: Style, link: String?)]) {
    var text = raw
    var runs: [(range: Range<Int>, style: Style, link: String?)] = []
    // swift-foundation ne lit pas encore le Markdown (`InlineMarkdown` y rend
    // toujours `nil`) ni ses attributs de présentation : sous Linux, texte brut.
    #if canImport(Darwin)
    if let attributed = InlineMarkdown.attributed(raw) {
      text = String(attributed.characters)
      var offset = 0
      for run in attributed.runs {
        let piece = String(attributed[run.range].characters)
        let count = piece.count
        var runStyle = base
        if let intent = run.inlinePresentationIntent {
          if intent.contains(.stronglyEmphasized) { runStyle = runStyle.with(.bold) }
          if intent.contains(.emphasized) { runStyle = runStyle.with(.italic) }
          if intent.contains(.strikethrough) { runStyle = runStyle.with(.strikethrough) }
          if intent.contains(.code) { runStyle = runStyle.foreground(.cyan) }
        }
        let link = run.link?.absoluteString
        if link != nil { runStyle = Theme.link.with(runStyle.attributes) }
        if runStyle != base || link != nil { runs.append((offset..<(offset + count), runStyle, link)) }
        offset += count
      }
    }
    #endif
    // Les adresses écrites en clair deviennent cliquables elles aussi.
    for detected in TextLinks.detect(in: text) {
      let start = text.distance(from: text.startIndex, to: detected.range.lowerBound)
      let end = text.distance(from: text.startIndex, to: detected.range.upperBound)
      guard !runs.contains(where: { $0.link != nil && $0.range.overlaps(start..<end) }) else { continue }
      runs.removeAll { $0.range.overlaps(start..<end) }
      runs.append((start..<end, Theme.link, detected.url.absoluteString))
    }
    runs.sort { $0.range.lowerBound < $1.range.lowerBound }
    return (text, runs)
  }

  private func attachmentLines(_ attachment: MessageAttachment, bubble: Int) -> [ThreadLine] {
    let name = attachment.filename ?? "fichier"
    if let voice = attachment.voice {
      return [.text([.init("🎤 Vocal · \(Dates.duration(voice.duration))", Theme.accent), .init("  o écouter", Theme.muted)])]
    }
    if attachment.isAudio {
      return [.text([.init("🎵 \(TextLayout.truncate(name, to: bubble - 14))", Theme.accent), .init("  o écouter", Theme.muted)])]
    }
    if attachment.isImage || attachment.isVideo {
      let label = attachment.isVideo ? "▶ Vidéo" : (attachment.isGIF ? "GIF" : "🖼 Photo")
      switch images.state(for: attachment) {
      case .ready(let ready):
        let cellWidth = capabilities.cellPixelWidth ?? size.cellPixelWidth ?? 9
        let cellHeight = capabilities.cellPixelHeight ?? size.cellPixelHeight ?? 18
        let box = ImageManager.cellSize(
          for: ready, maxColumns: min(bubble, 56), maxRows: min(16, max(5, size.rows * 40 / 100)),
          cellWidth: cellWidth, cellHeight: cellHeight
        )
        images.place(ready, columns: box.columns, rows: box.rows)
        var lines = (0..<box.rows).map { row in
          ThreadLine(content: .image(id: ready.id, row: row, columns: box.columns), width: box.columns)
        }
        if attachment.isVideo || attachment.isGIF {
          lines.append(.text([.init(label, Theme.muted), .init("  o ouvrir", Theme.muted)]))
        }
        return lines
      case .loading:
        return [.text([.init("\(label)…", Theme.muted)])]
      case .unavailable:
        let available = attachment.resolvedFileURL != nil
        return [.text([.init(label, Theme.accent), .init(available ? "  o ouvrir" : "  pas encore téléchargée", Theme.muted)])]
      }
    }
    return [.text([.init("📎 \(TextLayout.truncate(name, to: bubble - 12))", Theme.accent), .init("  o ouvrir", Theme.muted)])]
  }

  private func pollLines(_ poll: Poll, bubble: Int) -> [ThreadLine] {
    var lines: [ThreadLine] = [
      .text([.init("📊 ", Theme.accent), .init(TextLayout.truncate(poll.question, to: bubble - 3), Theme.strong)]),
    ]
    let counts = poll.answers.map { answer in poll.votesByVoter.values.filter { $0.contains(answer.id) }.count }
    let most = max(1, counts.max() ?? 1)
    let barWidth = 8
    for (answer, count) in zip(poll.answers, counts) {
      let mine = poll.myAnswerIDs.contains(answer.id)
      let filled = Int((Double(count) / Double(most) * Double(barWidth)).rounded())
      let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: barWidth - filled)
      lines.append(.text([
        .init(mine ? "● " : "○ ", mine ? Theme.accent : Theme.muted),
        .init(TextLayout.truncate(answer.text, to: max(6, bubble - barWidth - 8))),
        .init(" \(bar) \(count)", Theme.muted),
      ]))
    }
    lines.append(.text([.init(poll.isClosed ? "Sondage clos" : "V voter", Theme.muted)]))
    return lines
  }
}

extension ThreadLine {
  static func blank() -> ThreadLine { ThreadLine(content: .blank) }
}
