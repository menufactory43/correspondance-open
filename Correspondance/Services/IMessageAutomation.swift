import AppKit
import ApplicationServices
import Foundation
import CorrespondanceCore

// MARK: - Vocabulaire

/// Les six tapbacks natifs. L'identifiant AX est celui des éléments du menu
/// contextuel de Messages (`acknowledgment.type.*`, relevé dans `docs/IMESSAGE-AX.md`).
enum IMessageTapback: String, CaseIterable, Sendable {
  case heart, thumbsUp, thumbsDown, ha, exclamation, question

  var emoji: String {
    switch self {
    case .heart: "❤️"
    case .thumbsUp: "👍"
    case .thumbsDown: "👎"
    case .ha: "😂"
    case .exclamation: "‼️"
    case .question: "❓"
    }
  }

  var axIdentifier: String {
    switch self {
    case .heart: "acknowledgment.type.heart"
    case .thumbsUp: "acknowledgment.type.thumbs.up"
    case .thumbsDown: "acknowledgment.type.thumbs.down"
    case .ha: "acknowledgment.type.ha"
    case .exclamation: "acknowledgment.type.exclamation"
    case .question: "acknowledgment.type.question.mark"
    }
  }

  /// Libellés français du menu contextuel, en repli quand l'identifiant a bougé.
  var frenchLabels: [String] {
    switch self {
    case .heart: ["Cœur", "Coeur"]
    case .thumbsUp: ["Pouce vers le haut", "J’aime", "J'aime"]
    case .thumbsDown: ["Pouce vers le bas", "Je n’aime pas", "Je n'aime pas"]
    case .ha: ["Ha ha", "Haha"]
    case .exclamation: ["Point d’exclamation", "Point d'exclamation", "!!"]
    case .question: ["Point d’interrogation", "Point d'interrogation", "?"]
    }
  }

  static func matching(emoji: String) -> IMessageTapback? {
    let normalized = emoji.trimmingCharacters(in: .whitespaces)
    return allCases.first {
      $0.emoji == normalized || $0.emoji.unicodeScalars.first == normalized.unicodeScalars.first
    }
  }
}

/// Désignation complète d'une bulle : le fil (GUID chat.db), le message (GUID) et
/// son texte, pour la retrouver dans le transcript.
struct IMessageTarget: Sendable, Equatable {
  var chatGUID: String
  var chatIdentifier: String
  var messageGUID: String
  var messageText: String
  var isFromMe: Bool
}

// MARK: - Le service

/// Pilotage de Messages.app par l'API Accessibilité, **app cachée** — la mécanique
/// de Beeper Desktop : `NSWorkspace.openApplication` avec `activates = false` et
/// `hides = true`, puis `AXUIElement` sur une app qui n'est jamais au premier plan.
///
/// Un `actor` : toutes les actions sont sérialisées (jamais deux pilotages en même
/// temps), chacune sous une échéance de 5 s et annulable. Chaque action se termine
/// par une vérification dans `chat.db` sous 3 s — sans quoi elle est déclarée en
/// échec, jamais silencieusement réussie.
actor IMessageAutomation {
  static let shared = IMessageAutomation()

  /// Bundle id et chemin de Messages.
  private static let bundleID = "com.apple.MobileSMS"
  private static let appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")

  /// Identifiants AX relevés sur macOS 26.6.2 (voir `docs/IMESSAGE-AX.md`).
  private enum AXID {
    static let sidebar = "CKConversationListCollectionView"
    static let transcript = "TranscriptCollectionView"
    static let messageCell = "MessageCell"
    static let composer = "messageBodyField"
    static let editConfirm = "editing.confirm.button"
    static let editReject = "editing.reject.button"
    static let emojiTapback = "ACCESSIBILITY_ADD_EMOJI_TAPBACK"
    static let replyBalloon = "balloon.message.reply"
  }

  /// Délai maximal d'une séquence AX (le plan : 5 s).
  private static let actionDeadline: Duration = .seconds(5)
  /// Délai maximal de confirmation dans chat.db (le plan : 3 s).
  private static let confirmDeadline: Duration = .seconds(3)

  private let verifier = IMessageAutomationVerifier()

  /// Réglage « Automatisation Messages ». Faux = l'app se comporte comme avant.
  private(set) var isEnabled = false
  /// Option « fenêtre Messages hors écran » : repli quand une action exige une
  /// fenêtre visible (Messages ne dessine rien quand l'app est masquée).
  private(set) var movesWindowOffscreen = false
  private(set) var health: IMessageAutomationHealth = .unknown
  private(set) var lastProbe = IMessageAXProbe()

  func configure(enabled: Bool, offscreenWindow: Bool) {
    isEnabled = enabled
    movesWindowOffscreen = offscreenWindow
  }

  // MARK: - Santé

  /// Sonde l'arbre AX : au lancement et après chaque erreur.
  @discardableResult
  func probe() async -> IMessageAutomationHealth {
    var result = IMessageAXProbe(
      trusted: AXIsProcessTrusted(),
      messagesRunning: await Self.runningPID() != nil
    )
    if result.trusted, let pid = await Self.runningPID() {
      let app = AXUIElementCreateApplication(pid)
      result.menuBarFound = AX.attribute(app, kAXMenuBarAttribute) != nil
      let windows = (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
      result.pseudoWindows = !windows.isEmpty
        && windows.allSatisfy { AX.string($0, kAXRoleAttribute) != kAXWindowRole as String }
      if let window = Self.mainWindow(of: app) {
        result.windowFound = true
        result.sidebarFound = AX.firstDescendant(window, identifier: AXID.sidebar) != nil
        result.transcriptFound = AX.firstDescendant(window, identifier: AXID.transcript) != nil
      }
    }
    lastProbe = result
    health = IMessageAutomationHealth.evaluate(result, enabled: isEnabled)
    return health
  }

  // MARK: - Actions publiques

  /// Pose ou retire un tapback sur une bulle.
  /// Vérifié par une ligne `associated_message_type` 2000–2005 (ou 3000–3005 au retrait).
  func setTapback(_ tapback: IMessageTapback, on target: IMessageTarget, removing: Bool) async throws {
    try await run(describing: "tapback \(tapback.emoji)") { deadline in
      let since = try self.verifier.latestMessageRowID()
      let cell = try await self.locateCell(target, deadline: deadline)
      try await self.pressInContextMenu(
        of: cell,
        identifiers: [tapback.axIdentifier],
        titles: tapback.frenchLabels,
        deadline: deadline,
        describing: "le tapback \(tapback.emoji)"
      )
      let guid = target.messageGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.hasTapback(targetGUID: guid, sinceRowID: since, removal: removing)
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("le tapback \(tapback.emoji) n’apparaît pas dans chat.db")
      }
    }
  }

  /// Répond en citant : menu contextuel → « Répondre », puis le texte par le
  /// presse-papiers (⌘V) — plus fiable que la frappe simulée avec les accents.
  /// Vérifié par un `thread_originator_guid` pointant la bulle citée.
  func reply(to target: IMessageTarget, text: String) async throws {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw IMessageAutomationError.actionFailed("réponse vide") }

    try await run(describing: "réponse citée") { deadline in
      let since = try self.verifier.latestMessageRowID()
      let cell = try await self.locateCell(target, deadline: deadline)
      try await self.pressInContextMenu(
        of: cell,
        identifiers: [AXID.replyBalloon],
        titles: ["Répondre"],
        deadline: deadline,
        describing: "« Répondre »"
      )
      let pid = try await self.ensureRunningPID()
      let field = try await self.waitForElement(deadline: deadline, describing: "le champ de saisie") {
        let app = AXUIElementCreateApplication(pid)
        guard let window = Self.mainWindow(of: app) else { return nil }
        return AX.firstDescendant(window, identifier: AXID.composer)
          ?? AX.firstDescendant(window, role: kAXTextAreaRole as String)
      }
      AX.setFocused(field)
      try await self.paste(body, intoPID: pid)
      Keyboard.press(.return, modifiers: [], pid: pid)

      let guid = target.messageGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.hasReply(toGUID: guid, sinceRowID: since)
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("aucune réponse citée n’apparaît dans chat.db")
      }
    }
  }

  /// Modifie un message envoyé (≤ 15 min) : menu contextuel → « Modifier »,
  /// tout sélectionner, coller, valider. Vérifié par `date_edited`.
  func edit(_ target: IMessageTarget, newText: String) async throws {
    let body = newText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw IMessageAutomationError.actionFailed("texte de modification vide") }
    guard target.isFromMe else {
      throw IMessageAutomationError.actionFailed("on ne modifie que ses propres messages")
    }

    try await run(describing: "modification") { deadline in
      let cell = try await self.locateCell(target, deadline: deadline)
      try await self.pressInContextMenu(
        of: cell,
        identifiers: [],
        titles: ["Modifier"],
        deadline: deadline,
        describing: "« Modifier » (Messages ne l’offre que 15 min après l’envoi)"
      )
      let pid = try await self.ensureRunningPID()
      // Le champ éditable prend le focus dans la bulle elle-même.
      let field = try await self.waitForElement(deadline: deadline, describing: "le champ d’édition") {
        let app = AXUIElementCreateApplication(pid)
        return AX.attribute(app, kAXFocusedUIElementAttribute).map { AX.element($0) }
      }
      AX.setFocused(field)
      Keyboard.press(.a, modifiers: .maskCommand, pid: pid)
      try await self.paste(body, intoPID: pid)
      try await self.confirmEdit(pid: pid, deadline: deadline)

      let guid = target.messageGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.isEdited(messageGUID: guid)
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("`date_edited` reste vide dans chat.db")
      }
    }
  }

  /// Annule l'envoi (≤ 2 min). Vérifié par `date_retracted`.
  func undoSend(_ target: IMessageTarget) async throws {
    guard target.isFromMe else {
      throw IMessageAutomationError.actionFailed("on n’annule que ses propres envois")
    }
    try await run(describing: "annulation d’envoi") { deadline in
      let cell = try await self.locateCell(target, deadline: deadline)
      try await self.pressInContextMenu(
        of: cell,
        identifiers: [],
        titles: ["Annuler l’envoi", "Annuler l'envoi"],
        deadline: deadline,
        describing: "« Annuler l’envoi » (Messages ne l’offre que 2 min après l’envoi)"
      )
      // Messages peut demander confirmation par une feuille.
      let pid = try await self.ensureRunningPID()
      self.confirmSheetIfPresent(pid: pid)

      let guid = target.messageGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.isRetracted(messageGUID: guid)
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("`date_retracted` reste vide dans chat.db")
      }
    }
  }

  /// Marquer lu : il suffit que Messages sélectionne le fil — c'est elle qui
  /// émet l'accusé de lecture. Vérifié par `is_read` (plus aucun reçu non lu).
  func markRead(chatGUID: String, chatIdentifier: String) async throws {
    try await run(describing: "marquer comme lu") { deadline in
      guard try self.verifier.chatIdentifier(forChatGUID: chatGUID) != nil else {
        throw IMessageAutomationError.chatNotFound(chatIdentifier)
      }
      try await self.selectThread(chatGUID: chatGUID, chatIdentifier: chatIdentifier, deadline: deadline)
      let guid = chatGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.unreadCount(chatGUID: guid) == 0
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("`is_read` reste à 0 dans chat.db")
      }
    }
  }

  /// Marquer non lu : sélection du fil puis Conversation → « Marquer comme non lu »
  /// (⌘U). Passe par la barre de menus, plus stable que le menu contextuel de la ligne.
  func markUnread(chatGUID: String, chatIdentifier: String) async throws {
    try await run(describing: "marquer comme non lu") { deadline in
      guard try self.verifier.chatIdentifier(forChatGUID: chatGUID) != nil else {
        throw IMessageAutomationError.chatNotFound(chatIdentifier)
      }
      try await self.selectThread(chatGUID: chatGUID, chatIdentifier: chatIdentifier, deadline: deadline)
      let pid = try await self.ensureRunningPID()
      guard await self.pressMenuItem(pid: pid, menuID: "com.messages.conversationsmenu", titles: ["Marquer comme non lu"]) else {
        throw IMessageAutomationError.elementNotFound("Conversation → « Marquer comme non lu »")
      }
      let guid = chatGUID
      let confirmed = await self.verifier.waitUntil(timeout: Self.confirmDeadline) { [verifier = self.verifier] in
        try verifier.unreadCount(chatGUID: guid) > 0
      }
      guard confirmed else {
        throw IMessageAutomationError.notConfirmed("`is_read` reste à 1 dans chat.db")
      }
    }
  }

  // MARK: - Enveloppe commune

  /// Garde-fous partagés : réglage actif, santé, échéance de 5 s, annulation,
  /// et re-sonde à la moindre erreur.
  private func run(describing what: String, _ body: (ContinuousClock.Instant) async throws -> Void) async throws {
    guard isEnabled else { throw IMessageAutomationError.disabled }
    if !health.allowsActions {
      await probe()
      guard health.allowsActions else { throw IMessageAutomationError.unhealthy(health) }
    }
    let deadline = ContinuousClock.now + Self.actionDeadline
    do {
      try Task.checkCancellation()
      try await body(deadline)
    } catch is CancellationError {
      throw IMessageAutomationError.cancelled
    } catch {
      await probe()
      throw error
    }
  }

  // MARK: - Lancement caché

  /// Lance (ou retrouve) Messages **sans jamais l'activer**, puis la masque.
  /// C'est le geste de Beeper : l'app n'apparaît pas au premier plan.
  private func ensureRunningPID() async throws -> pid_t {
    if let pid = await Self.runningPID() {
      await Self.hideIfNeeded(pid: pid, offscreen: movesWindowOffscreen)
      return pid
    }
    guard let pid = await Self.launchHidden(url: nil) else {
      throw IMessageAutomationError.messagesUnavailable
    }
    return pid
  }

  /// Sélectionne un fil : lien profond `imessage://<handle>` ouvert sans activation.
  /// Repli : la ligne de la sidebar dont le titre correspond.
  private func selectThread(chatGUID: String, chatIdentifier: String, deadline: ContinuousClock.Instant) async throws {
    let pid = try await ensureRunningPID()
    if let encoded = chatIdentifier.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
       let url = URL(string: "imessage://\(encoded)")
    {
      _ = await Self.launchHidden(url: url)
    }
    // Laisser Messages appliquer la sélection, puis vérifier que le transcript existe.
    _ = try await waitForElement(deadline: deadline, describing: "le transcript de Messages") {
      let app = AXUIElementCreateApplication(pid)
      guard let window = Self.mainWindow(of: app) else { return nil }
      return AX.firstDescendant(window, identifier: AXID.transcript)
    }
    await Self.hideIfNeeded(pid: pid, offscreen: movesWindowOffscreen)
  }

  // MARK: - Localisation de la bulle

  /// Retrouve la cellule du transcript qui porte ce message. On ne s'appuie que
  /// sur le texte : l'arbre AX n'expose pas le `guid` de chat.db. Le `guid`, lui,
  /// sert à la vérification d'après-coup.
  private func locateCell(_ target: IMessageTarget, deadline: ContinuousClock.Instant) async throws -> AXUIElement {
    guard let stored = try verifier.message(guid: target.messageGUID, inChatGUID: target.chatGUID) else {
      throw IMessageAutomationError.messageNotFound
    }
    let needle = (stored.text.isEmpty ? target.messageText : stored.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try await selectThread(
      chatGUID: target.chatGUID,
      chatIdentifier: target.chatIdentifier,
      deadline: deadline
    )
    let pid = try await ensureRunningPID()
    return try await waitForElement(deadline: deadline, describing: "la bulle « \(needle.prefix(30)) »") {
      let app = AXUIElementCreateApplication(pid)
      guard let window = Self.mainWindow(of: app),
            let transcript = AX.firstDescendant(window, identifier: AXID.transcript)
      else { return nil }
      return Self.cell(in: transcript, matching: needle)
    }
  }

  /// La dernière cellule du transcript dont le texte contient celui du message.
  /// « Dernière » parce que Messages empile du plus ancien au plus récent.
  private static func cell(in transcript: AXUIElement, matching needle: String) -> AXUIElement? {
    guard !needle.isEmpty else { return nil }
    let candidates = AX.descendants(transcript, maxDepth: 12) { element in
      AX.string(element, "AXIdentifier") == AXID.messageCell
        || AX.string(element, kAXRoleAttribute) == kAXCellRole as String
        || AX.actions(element).contains(kAXShowMenuAction as String)
    }
    let matching = candidates.filter { element in
      let haystack = [
        AX.string(element, kAXValueAttribute),
        AX.string(element, kAXDescriptionAttribute),
        AX.string(element, kAXTitleAttribute),
      ]
      .compactMap { $0 }
      .joined(separator: " ")
      return haystack.localizedCaseInsensitiveContains(needle)
    }
    return matching.last
  }

  // MARK: - Menus contextuels

  /// `AXShowMenu` sur la bulle, puis presse l'entrée voulue (par identifiant AX
  /// d'abord, par libellé français ensuite). Referme le menu en cas d'échec.
  private func pressInContextMenu(
    of cell: AXUIElement,
    identifiers: [String],
    titles: [String],
    deadline: ContinuousClock.Instant,
    describing what: String
  ) async throws {
    AX.perform(cell, kAXShowMenuAction)
    let pid = try await ensureRunningPID()
    let menu = try await waitForElement(deadline: deadline, describing: "le menu contextuel") {
      let app = AXUIElementCreateApplication(pid)
      return AX.children(app).first { AX.string($0, kAXRoleAttribute) == kAXMenuRole as String }
    }
    let target = AX.descendants(menu, maxDepth: 6) { element in
      if let id = AX.string(element, "AXIdentifier"), identifiers.contains(id) { return true }
      guard let title = AX.string(element, kAXTitleAttribute) ?? AX.string(element, kAXDescriptionAttribute)
      else { return false }
      return titles.contains { title.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }.first

    guard let target else {
      AX.perform(menu, kAXCancelAction)
      throw IMessageAutomationError.elementNotFound(what)
    }
    guard AX.perform(target, kAXPressAction) else {
      AX.perform(menu, kAXCancelAction)
      throw IMessageAutomationError.actionFailed(what)
    }
  }

  /// Valide une modification : bouton `editing.confirm.button`, sinon ⏎.
  private func confirmEdit(pid: pid_t, deadline: ContinuousClock.Instant) async throws {
    let app = AXUIElementCreateApplication(pid)
    if let window = Self.mainWindow(of: app),
       let button = AX.firstDescendant(window, identifier: AXID.editConfirm),
       AX.perform(button, kAXPressAction)
    {
      return
    }
    Keyboard.press(.return, modifiers: [], pid: pid)
  }

  /// Presse le bouton par défaut d'une feuille de confirmation, s'il y en a une.
  private func confirmSheetIfPresent(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    guard let window = Self.mainWindow(of: app),
          let sheet = AX.firstDescendant(window, role: kAXSheetRole as String),
          let button = AX.descendants(sheet, maxDepth: 6, where: {
            AX.string($0, kAXRoleAttribute) == kAXButtonRole as String
          }).first
    else { return }
    AX.perform(button, kAXPressAction)
  }

  // MARK: - Attente d'un élément

  /// Attend qu'un élément apparaisse, jusqu'à l'échéance de l'action (5 s).
  private func waitForElement(
    deadline: ContinuousClock.Instant,
    describing what: String,
    _ find: () -> AXUIElement?
  ) async throws -> AXUIElement {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      if let found = find() { return found }
      try? await Task.sleep(for: .milliseconds(120))
    }
    if let found = find() { return found }
    throw IMessageAutomationError.timedOut(what)
  }

  // MARK: - Presse-papiers

  /// Colle un texte dans Messages, puis **restaure** le presse-papiers de l'utilisateur.
  private func paste(_ text: String, intoPID pid: pid_t) async throws {
    let saved = await Pasteboard.snapshot()
    await Pasteboard.set(text)
    Keyboard.press(.v, modifiers: .maskCommand, pid: pid)
    try? await Task.sleep(for: .milliseconds(180))
    await Pasteboard.restore(saved)
  }

  // MARK: - Enveloppe AppKit (main actor)

  @MainActor
  private static func runningPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
  }

  /// `activates = false` + `hides = true` : Messages travaille sans jamais passer devant.
  @MainActor
  private static func launchHidden(url: URL?) async -> pid_t? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.hides = true
    configuration.addsToRecentItems = false
    return await withCheckedContinuation { (continuation: CheckedContinuation<pid_t?, Never>) in
      let handler: @Sendable (NSRunningApplication?, Error?) -> Void = { app, _ in
        continuation.resume(returning: app?.processIdentifier)
      }
      if let url {
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: handler)
      } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: handler)
      }
    }
  }

  /// Masque Messages si elle ne l'est pas — `hides` de la configuration n'agit
  /// pas sur une app déjà lancée. Option « hors écran » : la fenêtre est poussée
  /// au-delà du bord droit plutôt que masquée, pour les actions qui exigent une
  /// fenêtre dessinée.
  @MainActor
  private static func hideIfNeeded(pid: pid_t, offscreen: Bool) {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
    if offscreen {
      if app.isHidden { app.unhide() }
      moveWindowOffscreen(pid: pid)
      return
    }
    if !app.isHidden { app.hide() }
  }

  /// Repli documenté : certaines actions veulent une fenêtre réellement dessinée.
  /// On la déplace hors de l'écran principal au lieu de masquer l'app.
  @MainActor
  private static func moveWindowOffscreen(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    guard let window = mainWindow(of: app) else { return }
    guard let screen = NSScreen.screens.first else { return }
    var origin = CGPoint(x: screen.frame.maxX + 64, y: screen.frame.minY)
    guard let value = AXValueCreate(.cgPoint, &origin) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
  }

  // MARK: - Fenêtre principale

  /// La vraie fenêtre de Messages. Quand l'app n'a aucune fenêtre, `AXWindows`
  /// renvoie un pseudo-élément de rôle `AXApplication` : on l'écarte.
  nonisolated static func mainWindow(of app: AXUIElement) -> AXUIElement? {
    let windows = (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let real = windows.first(where: { AX.string($0, kAXRoleAttribute) == kAXWindowRole as String }) {
      return real
    }
    if let raw = AX.attribute(app, kAXMainWindowAttribute) {
      let main = AX.element(raw)
      if AX.string(main, kAXRoleAttribute) == kAXWindowRole as String { return main }
    }
    return nil
  }

  /// Presse un élément de la barre de menus. C'est le chemin le plus stable :
  /// la barre de menus reste lisible même quand Messages est masquée (vérifié
  /// sur macOS 26.6.2). En revanche les entrées ne se *valident* qu'une fois le
  /// menu ouvert : on presse donc d'abord le titre du menu, puis l'entrée.
  private func pressMenuItem(pid: pid_t, menuID: String, titles: [String]) async -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let rawBar = AX.attribute(app, kAXMenuBarAttribute) else { return false }
    let bar = AX.element(rawBar)
    guard let menuTitle = AX.children(bar).first(where: { AX.string($0, "AXIdentifier") == menuID }) else { return false }
    AX.perform(menuTitle, kAXPressAction)
    try? await Task.sleep(for: .milliseconds(250))
    guard let list = AX.children(menuTitle).first else { return false }
    let item = AX.children(list).first { element in
      guard let title = AX.string(element, kAXTitleAttribute) else { return false }
      return titles.contains { title.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    guard let item else {
      AX.perform(list, kAXCancelAction)
      return false
    }
    let pressed = AX.perform(item, kAXPressAction)
    if !pressed { AX.perform(list, kAXCancelAction) }
    return pressed
  }
}

// MARK: - Couche AXUIElement

/// Petite couche au-dessus de l'API C d'Accessibilité. `nonisolated` : l'API AX
/// est utilisable depuis n'importe quel fil, et les `AXUIElement` ne quittent
/// jamais l'acteur.
enum AX {
  static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  static func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let text = value as? String { return text.isEmpty ? nil : text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  static func boolean(_ element: AXUIElement, _ name: String) -> Bool? {
    (attribute(element, name) as? NSNumber)?.boolValue
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
  }

  static func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
  }

  @discardableResult
  static func perform(_ element: AXUIElement, _ action: String) -> Bool {
    AXUIElementPerformAction(element, action as CFString) == .success
  }

  static func setFocused(_ element: AXUIElement) {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  }

  /// Parcours en largeur, borné en profondeur : l'arbre de Messages est profond
  /// et une descente non bornée coûte cher à chaque sondage.
  static func descendants(
    _ root: AXUIElement,
    maxDepth: Int,
    where matches: (AXUIElement) -> Bool
  ) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var frontier = [(root, 0)]
    while let (element, depth) = frontier.first {
      frontier.removeFirst()
      if matches(element) { found.append(element) }
      guard depth < maxDepth else { continue }
      for child in children(element) { frontier.append((child, depth + 1)) }
    }
    return found
  }

  static func firstDescendant(_ root: AXUIElement, identifier: String, maxDepth: Int = 14) -> AXUIElement? {
    descendants(root, maxDepth: maxDepth) { string($0, "AXIdentifier") == identifier }.first
  }

  static func firstDescendant(_ root: AXUIElement, role: String, maxDepth: Int = 14) -> AXUIElement? {
    descendants(root, maxDepth: maxDepth) { string($0, kAXRoleAttribute) == role }.first
  }

  /// Conversion sans copie d'un `CFTypeRef` connu comme `AXUIElement`.
  static func element(_ value: CFTypeRef) -> AXUIElement {
    unsafeBitCast(value, to: AXUIElement.self)
  }
}

// MARK: - Clavier

/// Frappes envoyées **au processus Messages** (`postToPid`) : elles arrivent
/// même quand l'app n'est pas au premier plan, ce qui est tout l'intérêt.
enum Keyboard {
  enum Key: CGKeyCode {
    case a = 0
    case v = 9
    case `return` = 36
    case escape = 53
  }

  static func press(_ key: Key, modifiers: CGEventFlags, pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: false)
    else { return }
    down.flags = modifiers
    up.flags = modifiers
    down.postToPid(pid)
    up.postToPid(pid)
  }
}

// MARK: - Presse-papiers

/// Sauvegarde/restauration du presse-papiers autour d'un ⌘V.
enum Pasteboard {
  /// Un élément du presse-papiers, réduit à ce qu'il faut pour le remettre.
  struct Item: Sendable {
    var payloads: [String: Data]
  }

  @MainActor
  static func snapshot() -> [Item] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
      var payloads: [String: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) { payloads[type.rawValue] = data }
      }
      return Item(payloads: payloads)
    }
  }

  @MainActor
  static func set(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  @MainActor
  static func restore(_ items: [Item]) {
    let board = NSPasteboard.general
    board.clearContents()
    guard !items.isEmpty else { return }
    let restored = items.map { item -> NSPasteboardItem in
      let entry = NSPasteboardItem()
      for (type, data) in item.payloads {
        entry.setData(data, forType: NSPasteboard.PasteboardType(type))
      }
      return entry
    }
    board.writeObjects(restored)
  }
}
