import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Correspondance dans le terminal.
///
///     correspondance-tui                 # sa propre session, son propre dossier de données
///     correspondance-tui --partager      # la session et la base de l'app (Mac ou Linux)
///     correspondance-tui --demo          # des conversations de démonstration, sans réseau
///     correspondance-tui --sans-images   # jamais d'images, même sous Kitty ou Ghostty
@main
struct CorrespondanceTUI {
  struct Options {
    var share = false
    var demoDirectory: String?
    var images = true
    var mouse = true
  }

  static let version = "0.1.0"

  static let usage = """
    correspondance-tui [--partager] [--demo [DOSSIER]] [--sans-images] [--sans-souris]
      --partager      utilise la session et la base de l'app installée sur cette machine
                      (par défaut, le terminal a les siennes : deux processus ne se
                      disputent jamais la même base)
      --demo          conversations de démonstration, sans Relais
      --sans-images   n'affiche aucune image, même là où le terminal le sait
      --sans-souris   laisse la souris au terminal (sélection de texte native)
    Variables : CORRESPONDANCE_HOME (dossier d'essai), CORRESPONDANCE_DEBUG
    Journal : <dossier de données>/terminal.log
    """

  static func main() async {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--partager", "--share": options.share = true
      case "--demo":
        if let next = arguments.first, !next.hasPrefix("-") {
          options.demoDirectory = arguments.removeFirst()
        } else {
          options.demoDirectory = ""
        }
      case "--sans-images", "--no-images": options.images = false
      case "--sans-souris", "--no-mouse": options.mouse = false
      case "--version": print(version); return
      case "-h", "--help": print(usage); return
      default:
        FileHandle.standardError.write(Data("argument inconnu : \(argument)\n\(usage)\n".utf8))
        exit(2)
      }
    }

    guard isatty(STDIN_FILENO) != 0 else {
      FileHandle.standardError.write(Data("✗ correspondance-tui a besoin d'un terminal interactif.\n".utf8))
      exit(1)
    }

    // Par défaut, un dossier et une session à part : l'app du Mac (ou le
    // serveur Linux) peut tourner en même temps sans que deux boucles /sync
    // écrivent la même base.
    if !options.share, ProcessInfo.processInfo.environment["CORRESPONDANCE_HOME"] == nil {
      setenv("CORRESPONDANCE_HOME", "terminal", 1)
    }
    redirectStandardError()
    // Le nom sous lequel le Relais liste cette session, à côté du Mac et de l'iPhone.
    MatrixClient.deviceDisplayName = "Correspondance (terminal · \(shortHostName()))"

    // Le mandataire Tailcat embarqué, à côté du binaire, comme sous Linux.
    if ProcessInfo.processInfo.environment["CORRESPONDANCE_TAILCAT"] == nil {
      let neighbour = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tailcat").path
      if FileManager.default.isExecutableFile(atPath: neighbour) { setenv("CORRESPONDANCE_TAILCAT", neighbour, 1) }
    }

    let demo = options.demoDirectory.map { DemoCatalogue.load(directory: $0) }
    if options.demoDirectory != nil, demo == nil {
      FileHandle.standardError.write(Data("✗ fixtures de démonstration introuvables\n".utf8))
    }
    let app = await MainActor.run { TUIApp(options: options, demo: demo ?? nil) }
    await app.run()
    exit(0)
  }

  /// Le nom court de la machine, sans passer par le DNS (`hostName` peut bloquer).
  static func shortHostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return "?" }
    let name = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return name.split(separator: ".").first.map(String.init) ?? name
  }

  /// Le journal du magasin écrit sur la sortie d'erreur ; dans une TUI, elle
  /// barbouillerait l'écran. Elle part donc dans un fichier.
  static func redirectStandardError() {
    let directory = CorrespondanceHome.directory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("terminal.log").path
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { return }
    dup2(descriptor, STDERR_FILENO)
    close(descriptor)
  }
}
