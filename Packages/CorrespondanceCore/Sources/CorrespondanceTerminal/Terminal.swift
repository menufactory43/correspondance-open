#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Le terminal lui-même : mode brut, écran alternatif, taille, écriture.
///
/// Tout ce qui touche un descripteur est ici, et seulement ici. Le reste de la
/// TUI dessine dans des grilles et reçoit des événements.
public final class Terminal: @unchecked Sendable {
  public struct Size: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Taille de la fenêtre en pixels, quand le terminal la donne (0 sinon).
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var cellPixelWidth: Double? {
      guard pixelWidth > 0, columns > 0 else { return nil }
      return Double(pixelWidth) / Double(columns)
    }

    public var cellPixelHeight: Double? {
      guard pixelHeight > 0, rows > 0 else { return nil }
      return Double(pixelHeight) / Double(rows)
    }
  }

  private let input: Int32 = STDIN_FILENO
  private let output: Int32
  private var original = termios()
  private var isRaw = false
  private let lock = NSLock()

  public init() {
    // La sortie va à /dev/tty quand stdout est redirigé : `correspondance-tui > x`
    // dessine quand même à l'écran.
    if isatty(STDOUT_FILENO) != 0 {
      output = STDOUT_FILENO
    } else {
      let tty = open("/dev/tty", O_WRONLY)
      output = tty >= 0 ? tty : STDOUT_FILENO
    }
  }

  public var isInteractive: Bool { isatty(input) != 0 }

  // MARK: - Mode brut

  /// Passe en mode brut et lève les modes dont la TUI a besoin.
  public func enter(mouse: Bool = true) {
    lock.lock()
    defer { lock.unlock() }
    guard !isRaw else { return }
    tcgetattr(input, &original)
    var raw = original
    raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
    raw.c_oflag &= ~tcflag_t(OPOST)
    raw.c_cflag |= tcflag_t(CS8)
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
    withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
      pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 0
      }
    }
    tcsetattr(input, TCSAFLUSH, &raw)
    isRaw = true

    var sequence = ""
    sequence += "\u{1B}[?1049h" // écran alternatif
    sequence += "\u{1B}[?25l" // curseur caché
    sequence += "\u{1B}[?7l" // pas de retour à la ligne automatique
    sequence += "\u{1B}[?2004h" // collage entre crochets
    sequence += "\u{1B}[?1004h" // focus
    sequence += "\u{1B}[?2027h" // graphèmes (Ghostty, Kitty récents)
    sequence += "\u{1B}[>1u" // protocole clavier Kitty : désambiguïser
    if mouse { sequence += "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h" }
    writeUnlocked(Array(sequence.utf8))
  }

  /// Rend le terminal comme on l'a trouvé. Sans danger si appelé deux fois.
  public func leave() {
    lock.lock()
    defer { lock.unlock() }
    guard isRaw else { return }
    var sequence = ""
    sequence += "\u{1B}[?2026l"
    sequence += "\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1000l"
    sequence += "\u{1B}[<u"
    sequence += "\u{1B}[?2027l"
    sequence += "\u{1B}[?1004l"
    sequence += "\u{1B}[?2004l"
    sequence += "\u{1B}[?7h"
    sequence += "\u{1B}]8;;\u{1B}\\"
    sequence += "\u{1B}[0m\u{1B}[0 q\u{1B}[?25h"
    sequence += "\u{1B}[?1049l"
    writeUnlocked(Array(sequence.utf8))
    tcsetattr(input, TCSAFLUSH, &original)
    isRaw = false
  }

  // MARK: - Taille

  public func size() -> Size {
    var window = winsize()
    if ioctl(output, UInt(TIOCGWINSZ), &window) == 0, window.ws_col > 0 {
      return Size(columns: Int(window.ws_col), rows: Int(window.ws_row), pixelWidth: Int(window.ws_xpixel), pixelHeight: Int(window.ws_ypixel))
    }
    return Size(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
  }

  // MARK: - Écriture

  /// Écrit tout, en un minimum d'appels système. Bloquant : une image doit
  /// partir entière avant la suivante.
  public func write(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    writeUnlocked(bytes)
  }

  public func write(_ string: String) { write(Array(string.utf8)) }

  private func writeUnlocked(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
      guard var base = raw.baseAddress else { return }
      var remaining = raw.count
      while remaining > 0 {
        #if canImport(Darwin)
        let written = Darwin.write(output, base, remaining)
        #elseif canImport(Glibc)
        let written = Glibc.write(output, base, remaining)
        #else
        let written = Musl.write(output, base, remaining)
        #endif
        if written < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          return
        }
        remaining -= written
        base += written
      }
    }
  }
}
