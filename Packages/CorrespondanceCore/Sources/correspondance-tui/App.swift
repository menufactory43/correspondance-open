import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// La TUI : un magasin, une grille, une boucle d'événements.
///
/// Le principe de rafraîchissement est celui de SwiftUI, sans SwiftUI : le
/// dessin d'une image se fait **dans** `withObservationTracking`. Seules les
/// propriétés du magasin effectivement lues pour dessiner réveillent l'écran
/// quand elles changent — un `/sync` qui ne touche pas ce qu'on regarde ne
/// coûte pas une image. Les réveils sont fusionnés (au plus une image par
/// passe, plafonnée à 120 Hz) et l'image part en un seul `write` synchronisé.
@MainActor
final class TUIApp {
  let options: CorrespondanceTUI.Options
  let store: RelayStore
  let terminal = Terminal()
  let reader = InputReader()
  let images: ImageManager

  var renderer = Renderer()
  var canvas = Canvas(width: 0, height: 0)
  var size: Terminal.Size
  var ui = UIState()
  var capabilities = Capabilities()
  var threadCache = ThreadLayoutCache()

  private var renderScheduled = false
  private var lastFrame = DispatchTime.now()
  private var running = true
  private var signalSources: [DispatchSourceSignal] = []
  private var openTask: Task<Void, Never>?
  private var lastWindowTitle = ""

  struct Capabilities {
    var probed = false
    var kittyGraphics = false
    var kittyKeyboard = false
    var synchronizedOutput: Bool?
    var cellPixelWidth: Double?
    var cellPixelHeight: Double?
    /// Kitty lui-même : notifications OSC 99. Les autres : OSC 9.
    var isKitty = ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"] != nil
      || ProcessInfo.processInfo.environment["TERM"] == "xterm-kitty"
  }

  init(options: CorrespondanceTUI.Options, demo: DemoCatalogue?) {
    self.options = options
    store = RelayStore(demo: demo != nil)
    size = terminal.size()
    let remote = ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil
      || ProcessInfo.processInfo.environment["SSH_TTY"] != nil
    images = ImageManager(
      directory: CorrespondanceHome.directory().appendingPathComponent("vignettes-terminal", isDirectory: true),
      transmission: remote ? .direct : .file
    )
    if let demo {
      store.installDemo(
        conversations: demo.conversations, messages: demo.messages, state: demo.state,
        typingLabels: demo.typingLabels, merged: demo.merged
      )
    }
    images.onChange = { [weak self] in self?.threadCache.invalidateImages(); self?.setNeedsRender() }
  }

  // MARK: - Boucle

  func run() async {
    installSignalHandlers()
    terminal.enter(mouse: options.mouse)
    terminal.write(KittyGraphics.probe)
    reader.start()

    store.notificationPresenter = { [weak self] title, body in
      guard let self else { return }
      self.terminal.write(TerminalSequences.notification(title: title, body: body, kitty: self.capabilities.isKitty))
    }

    // Si le terminal ne répond pas au sondage (tmux ancien, console Linux), on
    // n'attend pas plus d'une demi-seconde pour lui supposer le minimum.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      self?.finishProbe()
    }

    Task { @MainActor [weak self] in await self?.store.start() }
    // Les messages programmés partent d'ici, comme depuis le serveur Linux.
    Task { @MainActor [weak self] in
      while let self, self.running {
        try? await Task.sleep(for: .seconds(30))
        await self.store.flushDueScheduledMessages()
      }
    }
    // L'horloge : les « il y a 5 min » et les rappels échus bougent seuls.
    Task { @MainActor [weak self] in
      while let self, self.running {
        try? await Task.sleep(for: .seconds(30))
        self.setNeedsRender()
      }
    }

    renderNow()
    for await event in reader.events {
      handle(event)
      if !running { break }
    }
    shutdown()
  }

  func quit() {
    running = false
    reader.stop()
  }

  private func shutdown() {
    running = false
    terminal.write(images.deleteAll())
    terminal.leave()
  }

  // MARK: - Signaux

  private func installSignalHandlers() {
    let handlers: [(Int32, @MainActor (TUIApp) -> Void)] = [
      (SIGWINCH, { $0.resized() }),
      (SIGTERM, { $0.quit() }),
      (SIGHUP, { $0.quit() }),
      (SIGINT, { $0.quit() }),
      (SIGCONT, { $0.resumedFromSuspend() }),
    ]
    for (number, action) in handlers {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          action(self)
        }
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func resized() {
    size = terminal.size()
    renderer.invalidate()
    threadCache.removeAll()
    setNeedsRender()
  }

  /// ^Z : on rend le terminal au shell, on s'arrête, et on repeint tout au retour.
  func suspend() {
    terminal.leave()
    signal(SIGTSTP, SIG_DFL)
    kill(getpid(), SIGTSTP)
  }

  private func resumedFromSuspend() {
    terminal.enter(mouse: options.mouse)
    size = terminal.size()
    renderer.invalidate()
    images.retransmitAll()
    setNeedsRender()
  }

  // MARK: - Événements

  private func handle(_ event: InputEvent) {
    switch event {
    case .key(let key):
      handleKey(key)
    case .paste(let text):
      handlePaste(text)
    case .mouse(let mouse):
      handleMouse(mouse)
    case .focus(let focused):
      ui.terminalHasFocus = focused
      store.isWindowVisible = focused
    case .graphicsReply(let id, let message):
      if id == KittyGraphics.probeID { capabilities.kittyGraphics = message.hasPrefix("OK") }
    case .keyboardProtocolFlags:
      capabilities.kittyKeyboard = true
    case .modeReport(let mode, let value):
      if mode == 2026 { capabilities.synchronizedOutput = value == 1 || value == 2 }
    case .cellPixelSize(let width, let height):
      if width > 0, height > 0 {
        capabilities.cellPixelWidth = Double(width)
        capabilities.cellPixelHeight = Double(height)
      }
    case .primaryDeviceAttributes:
      finishProbe()
    }
    setNeedsRender()
  }

  private func finishProbe() {
    guard !capabilities.probed else { return }
    capabilities.probed = true
    images.isEnabled = options.images && capabilities.kittyGraphics
    if let synchronized = capabilities.synchronizedOutput { renderer.synchronizedOutput = synchronized }
    setNeedsRender()
  }

  // MARK: - Rendu

  /// Demande une image. Plusieurs demandes dans la même passe n'en font qu'une.
  func setNeedsRender() {
    guard !renderScheduled, running else { return }
    renderScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Au plus 120 images par seconde : au-delà, l'œil ne voit rien de plus
      // et le terminal ferait le travail pour rien.
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.lastFrame.uptimeNanoseconds) / 1e9
      let budget = 1.0 / 120.0
      if elapsed < budget {
        try? await Task.sleep(for: .milliseconds(Int(((budget - elapsed) * 1000).rounded(.up))))
      }
      self.renderScheduled = false
      self.renderNow()
    }
  }

  func renderNow() {
    guard running else { return }
    lastFrame = DispatchTime.now()
    if canvas.width != size.columns || canvas.height != size.rows {
      canvas.resize(width: size.columns, height: size.rows)
    } else {
      canvas.clear()
    }
    withObservationTracking {
      draw()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.setNeedsRender() }
    }
    let prefix = images.takePendingBytes()
    let bytes = renderer.render(canvas, extraPrefix: prefix)
    terminal.write(bytes)
    updateWindowTitle()
  }

  private func updateWindowTitle() {
    let unread = store.unreadCount(for: nil)
    let title = unread > 0 ? "Correspondance (\(unread))" : "Correspondance"
    guard title != lastWindowTitle else { return }
    lastWindowTitle = title
    terminal.write(TerminalSequences.windowTitle(title))
  }

  // MARK: - Ouvrir un fil

  /// Ouvre un fil après un court repos de la sélection : parcourir la liste à
  /// la flèche ne marque pas tout comme lu au passage.
  func scheduleOpen(_ conversationID: String?, delay: Duration = .milliseconds(220)) {
    openTask?.cancel()
    guard let conversationID else { return }
    openTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      await self.store.open(conversationID: conversationID)
    }
  }

  /// Un message court dans la barre d'état, qui s'efface seul.
  func toast(_ text: String, isError: Bool = false) {
    ui.toast = UIState.Toast(text: text, isError: isError, until: Date().addingTimeInterval(isError ? 6 : 3))
    setNeedsRender()
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(isError ? 6.1 : 3.1))
      self?.setNeedsRender()
    }
  }
}
