import Foundation

/// Lancer un moteur : trouver son exécutable, lui parler, l'attendre.
/// Commun à tous les backends — `claude` aujourd'hui, `hermes` aussi, les
/// suivants gratuitement.
enum Subprocess {

  /// L'exécutable `name`, au chemin configuré s'il existe, sinon aux endroits
  /// habituels puis dans le `PATH`.
  static func find(_ name: String, configured: String?) -> String? {
    if let configured, FileManager.default.isExecutableFile(atPath: configured) { return configured }
    let home = FileManager.default.homeDirectoryForCurrentUser.path()
    let candidates = [
      "\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
    ]
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
      let candidate = "\(dir)/\(name)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// Ce qu'un processus a rendu. Hermes met sa plomberie (`session_id: …`)
  /// sur stderr : les backends qui en ont besoin la trouvent ici.
  struct Output: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
  }

  /// Bloquant, à appeler hors des acteurs. `Process` n'est pas `Sendable` :
  /// il naît et meurt ici.
  @discardableResult
  static func run(
    binary: String,
    arguments: [String],
    stdin: String,
    cwd: String?,
    timeoutSeconds: Int,
    extraEnv: [String: String] = [:]
  ) throws -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    // Un `claude` lancé depuis un autre `claude` refuse de démarrer : on ne
    // lui transmet pas les marqueurs de la session parente.
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
    for (key, value) in extraEnv { env[key] = value }
    process.environment = env

    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()

    // Lire avant d'attendre : un tube plein bloquerait l'enfant.
    let outData = output.fileHandleForReading.readDataToEndOfFile()
    let errData = errors.fileHandleForReading.readDataToEndOfFile()

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()
        throw AgentBackendError.timedOut(seconds: timeoutSeconds)
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard process.terminationStatus == 0 || !outData.isEmpty else {
      let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw AgentBackendError.exit(code: process.terminationStatus, stderr: String(stderr.suffix(400)))
    }
    return Output(stdout: outData, stderr: errData, status: process.terminationStatus)
  }
}
