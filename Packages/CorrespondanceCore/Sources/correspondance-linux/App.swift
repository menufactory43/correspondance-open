import CorrespondanceCore
import Foundation

/// Correspondance pour Linux.
///
/// Le même cœur que le Mac et l'iPhone — client Matrix, magasin local,
/// état de conversation du Relais — servi à un navigateur sur `127.0.0.1`.
/// Pas de GTK ni de Qt : un binaire statique qui marche sur n'importe quelle
/// distribution, et une interface qui est la nôtre au pixel près, dans la
/// fenêtre que le bureau sait déjà ouvrir.
///
///     correspondance                 # ouvre le navigateur sur l'inbox
///     correspondance --port 7333     # port fixe (par défaut : libre au hasard)
///     correspondance --no-open       # n'ouvre pas le navigateur, affiche l'adresse
///     correspondance --ui ./ui       # dossier de l'interface (sinon ../share/correspondance/ui)
@main
struct CorrespondanceLinux {
  static func main() async {
    // Un navigateur qui referme son flux d'événements pendant qu'on lui écrit
    // vaudrait un SIGPIPE, c'est-à-dire la mort du processus : on l'ignore, et
    // `send` rend simplement une erreur que le serveur sait lire.
    signal(SIGPIPE, SIG_IGN)
    var port: UInt16 = 0
    var openBrowser = true
    var uiPath: String? = ProcessInfo.processInfo.environment["CORRESPONDANCE_UI"]
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--port": port = UInt16(arguments.isEmpty ? "" : arguments.removeFirst()) ?? 0
      case "--no-open": openBrowser = false
      case "--ui": uiPath = arguments.isEmpty ? nil : arguments.removeFirst()
      case "--version": print(Self.version); return
      case "-h", "--help": print(Self.usage); return
      default: print("argument inconnu : \(argument)\n\(Self.usage)"); exit(2)
      }
    }
    if ProcessInfo.processInfo.environment["CORRESPONDANCE_NO_OPEN"] != nil { openBrowser = false }

    let (uiDirectory, fontsDirectory) = Self.locateResources(uiPath: uiPath)
    guard FileManager.default.fileExists(atPath: uiDirectory.appendingPathComponent("index.html").path) else {
      FileHandle.standardError.write(Data("✗ interface introuvable dans \(uiDirectory.path) — donne son dossier avec --ui\n".utf8))
      exit(1)
    }

    let store = await MainActor.run { RelayStore() }
    let api = await MainActor.run { API(store: store, uiDirectory: uiDirectory, fontsDirectory: fontsDirectory) }
    let server = HTTPServer(port: port) { request in await api.handle(request) }
    let actual: UInt16
    do { actual = try server.start() } catch {
      FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
      exit(1)
    }
    let origin = "http://127.0.0.1:\(actual)"
    let address = "\(origin)/#t=\(await MainActor.run { api.token })"
    await MainActor.run { api.setOrigin(origin) }

    print("Correspondance pour Linux \(Self.version)")
    print("→ \(address)")
    print("  données : \(CorrespondanceHome.directory().path)")
    // Redirigé vers un fichier ou un journal, stdout est mis en tampon : l'adresse
    // n'arriverait qu'à la sortie du processus, c'est-à-dire trop tard.
    fflush(stdout)
    if openBrowser {
      if !Platform.open(URL(string: address)!) {
        print("  (xdg-open n'a pas ouvert de navigateur — ouvre l'adresse ci-dessus à la main)")
      }
    }

    await store.start()
    // Tant que le processus vit, le magasin synchronise et le serveur répond.
    // Ce qui doit tourner à intervalle régulier — les messages programmés —
    // se fait ici, sans dépendre d'un premier plan que Linux n'a pas.
    while true {
      try? await Task.sleep(for: .seconds(30))
      await store.flushDueScheduledMessages()
    }
  }

  static let version = "0.1.0"

  static let usage = """
    correspondance [--port N] [--no-open] [--ui DOSSIER]
      --port N     écoute sur ce port (127.0.0.1 seulement) ; sinon un port libre
      --no-open    n'ouvre pas le navigateur ; l'adresse (avec son jeton) s'affiche
      --ui DOSSIER le dossier de l'interface (index.html, app.js, app.css)
    Variables : CORRESPONDANCE_HOME (essai à part), CORRESPONDANCE_UI, CORRESPONDANCE_NO_OPEN
    """

  /// L'interface et les polices : à côté du binaire (`../share/correspondance`),
  /// comme un paquet Linux les range, ou là où on nous le dit.
  static func locateResources(uiPath: String?) -> (URL, URL) {
    if let uiPath {
      let ui = URL(fileURLWithPath: uiPath).standardizedFileURL
      let fonts = ui.deletingLastPathComponent().appendingPathComponent("fonts", isDirectory: true)
      return (ui, FileManager.default.fileExists(atPath: fonts.path) ? fonts : ui.appendingPathComponent("fonts"))
    }
    let executable = URL(fileURLWithPath: Self.executablePath()).standardizedFileURL
    let candidates = [
      executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/correspondance", isDirectory: true),
      executable.deletingLastPathComponent().appendingPathComponent("share/correspondance", isDirectory: true),
      executable.deletingLastPathComponent(),
    ]
    for base in candidates where FileManager.default.fileExists(atPath: base.appendingPathComponent("ui/index.html").path) {
      return (base.appendingPathComponent("ui", isDirectory: true), base.appendingPathComponent("fonts", isDirectory: true))
    }
    let fallback = candidates[0]
    return (fallback.appendingPathComponent("ui", isDirectory: true), fallback.appendingPathComponent("fonts", isDirectory: true))
  }

  static func executablePath() -> String {
    if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return resolved }
    return CommandLine.arguments.first.map { URL(fileURLWithPath: $0).path } ?? "."
  }
}
