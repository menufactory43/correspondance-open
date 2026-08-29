import Foundation

/// Surveille `~/Library/Messages/chat.db-wal` et signale les écritures.
///
/// iMessage n'a pas de flux temps réel : Messages écrit dans le journal WAL de SQLite
/// à chaque message. Un `DispatchSource` sur ce fichier suffit donc à savoir « il s'est
/// passé quelque chose », sans interroger la base en boucle.
///
/// Le WAL est **recréé** à chaque point de contrôle SQLite : le descripteur devient
/// alors caduc et il faut se ré-armer sur le nouveau fichier — c'est le cas
/// `.delete` / `.rename`, sans lequel la surveillance s'arrêterait silencieusement
/// au bout de quelques minutes.
final class IMessageWatcher: @unchecked Sendable {
  /// Fenêtre d'apaisement : Messages écrit plusieurs fois par message reçu.
  private let debounce: Duration
  private let queue = DispatchQueue(label: "app.correspondance.imessage-watcher")
  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var debounceTask: Task<Void, Never>?
  /// Bascule différée du fichier de base vers le WAL, quand celui-ci (ré)apparaît.
  private var rearmTask: Task<Void, Never>?
  /// Vrai quand on surveille `chat.db` faute de WAL : état transitoire à corriger.
  private var isWatchingFallback = false
  private var onChange: (@Sendable () async -> Void)?
  private var isStopped = false

  /// Chemins surveillés, dans l'ordre de préférence : le WAL bouge à chaque écriture,
  /// la base elle-même ne bouge qu'aux points de contrôle.
  private let walURL: URL
  private let databaseURL: URL

  init(
    databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db"),
    debounce: Duration = .milliseconds(500)
  ) {
    self.databaseURL = databaseURL
    self.walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    self.debounce = debounce
  }

  deinit {
    closeDescriptor()
  }

  /// `false` si aucun fichier n'est lisible (accès disque non accordé) : l'appelant
  /// reste alors sur l'actualisation manuelle plutôt que de croire à un temps réel absent.
  @discardableResult
  func start(onChange: @escaping @Sendable () async -> Void) -> Bool {
    queue.sync {
      self.onChange = onChange
      self.isStopped = false
      return arm()
    }
  }

  func stop() {
    queue.sync {
      isStopped = true
      debounceTask?.cancel()
      debounceTask = nil
      rearmTask?.cancel()
      rearmTask = nil
      closeDescriptor()
    }
  }

  // MARK: - Privé

  /// À appeler sur `queue`.
  private func arm() -> Bool {
    closeDescriptor()
    guard !isStopped else { return false }

    // Le WAL n'existe pas tant que Messages n'a rien écrit — et disparaît à chaque
    // point de contrôle SQLite. On se rabat alors sur la base, et on repasse sur le
    // WAL dès qu'il réapparaît : sans cette bascule, un checkpoint arrêterait la
    // surveillance en silence, puisque la base ne bouge plus entre deux checkpoints.
    let walExists = FileManager.default.fileExists(atPath: walURL.path)
    let target = walExists ? walURL : databaseURL
    let fd = open(target.path, O_EVTONLY)
    guard fd >= 0 else { return false }
    descriptor = fd
    isWatchingFallback = !walExists
    if isWatchingFallback { scheduleRearmOnWALAppearance() }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete, .rename, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let flags = source.data
      self.scheduleNotification()
      // Point de contrôle SQLite : le fichier surveillé n'existe plus, il faut
      // rouvrir un descripteur sur celui qui vient de le remplacer.
      if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
        _ = self.arm()
      }
    }
    source.setCancelHandler { [fd] in
      close(fd)
    }
    self.source = source
    source.resume()
    return true
  }

  /// Attend que le WAL réapparaisse pour s'y rebrancher. À appeler sur `queue`.
  private func scheduleRearmOnWALAppearance() {
    rearmTask?.cancel()
    let wal = walURL.path
    rearmTask = Task { [weak self] in
      // Un checkpoint recrée le WAL en quelques millisecondes ; une session
      // Messages inactive peut le laisser absent longtemps. On sonde sans hâte.
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let self else { return }
        guard FileManager.default.fileExists(atPath: wal) else { continue }
        self.queue.async {
          guard !self.isStopped, self.isWatchingFallback else { return }
          _ = self.arm()
        }
        return
      }
    }
  }

  /// À appeler sur `queue`.
  private func scheduleNotification() {
    debounceTask?.cancel()
    let handler = onChange
    let delay = debounce
    debounceTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, self != nil else { return }
      await handler?()
    }
  }

  /// À appeler sur `queue`. Le `cancelHandler` referme le descripteur.
  private func closeDescriptor() {
    source?.cancel()
    source = nil
    descriptor = -1
  }
}
