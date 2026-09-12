#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Lit l'entrée standard sur un fil à lui et livre des événements.
///
/// Un fil dédié bloqué dans `poll` plutôt qu'une tâche qui scrute : zéro
/// réveil quand personne ne tape, et une touche arrive au magasin dans la
/// milliseconde. La seule attente volontaire est celle qui distingue la touche
/// Échap du début d'une séquence, quand le protocole clavier Kitty n'est pas
/// là pour lever l'ambiguïté — 25 ms, sous le seuil de perception.
public final class InputReader: @unchecked Sendable {
  public let events: AsyncStream<InputEvent>
  private let continuation: AsyncStream<InputEvent>.Continuation
  private var thread: Thread?
  private let stopPipe: [Int32]

  public init() {
    var continuation: AsyncStream<InputEvent>.Continuation!
    events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
    var fds: [Int32] = [0, 0]
    _ = pipe(&fds)
    stopPipe = fds
  }

  public func start() {
    guard thread == nil else { return }
    let thread = Thread { [self] in run() }
    thread.name = "correspondance.tui.input"
    thread.qualityOfService = .userInteractive
    self.thread = thread
    thread.start()
  }

  /// Arrête la lecture. Le fil sort de `poll` par le tube d'arrêt.
  public func stop() {
    var byte: UInt8 = 1
    _ = withUnsafePointer(to: &byte) { Foundation.write(stopPipe[1], $0, 1) }
    continuation.finish()
  }

  /// Suspend la lecture sans la finir (le temps d'un ^Z) : on la reprend par `resume`.
  private let suspended = NSCondition()
  private var isSuspended = false

  public func suspend() {
    suspended.lock()
    isSuspended = true
    suspended.unlock()
  }

  public func resume() {
    suspended.lock()
    isSuspended = false
    suspended.broadcast()
    suspended.unlock()
  }

  private func run() {
    var parser = InputParser()
    var buffer = [UInt8](repeating: 0, count: 8192)
    var fds = [
      pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
      pollfd(fd: stopPipe[0], events: Int16(POLLIN), revents: 0),
    ]
    while true {
      suspended.lock()
      while isSuspended { suspended.wait() }
      suspended.unlock()

      let timeout: Int32 = parser.hasLoneEscape ? 25 : -1
      let ready = poll(&fds, 2, timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        return
      }
      if fds[1].revents != 0 { return }
      if ready == 0 {
        for event in parser.flushLoneEscape() { continuation.yield(event) }
        continue
      }
      guard fds[0].revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
      let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
      if count <= 0 {
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        continuation.finish()
        return
      }
      for event in parser.feed(buffer[0..<count]) { continuation.yield(event) }
    }
  }
}
