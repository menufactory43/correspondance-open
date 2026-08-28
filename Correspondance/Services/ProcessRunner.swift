import Foundation

enum ProcessRunner {
  struct Result: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  /// Lance un process hors du main thread, avec timeout.
  /// stdout/stderr vont dans des fichiers temporaires pour éviter le **deadlock de pipe**
  /// (ex. `listGroups` ~60 Ko qui remplit le buffer et bloque Java).
  static func run(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval
  ) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let result = try runSync(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
          )
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func runSync(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval
  ) throws -> Result {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("correspondance-proc-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let outURL = dir.appendingPathComponent("stdout.txt")
    let errURL = dir.appendingPathComponent("stderr.txt")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)

    guard let outHandle = try? FileHandle(forWritingTo: outURL),
          let errHandle = try? FileHandle(forWritingTo: errURL)
    else {
      throw ProcessRunnerError.ioFailed
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outHandle
    process.standardError = errHandle
    // Environnement minimal mais avec Homebrew (signal-cli / Java emballé).
    var env = ProcessInfo.processInfo.environment
    let path = env["PATH"] ?? "/usr/bin:/bin"
    if !path.contains("/opt/homebrew/bin") {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
    }
    process.environment = env

    try process.run()

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      process.waitUntilExit()
      group.leave()
    }

    let waited = group.wait(timeout: .now() + timeoutSeconds)
    try? outHandle.close()
    try? errHandle.close()

    if waited == .timedOut {
      process.terminate()
      _ = group.wait(timeout: .now() + 2)
      throw ProcessRunnerError.timedOut(timeoutSeconds)
    }

    let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return Result(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

enum ProcessRunnerError: LocalizedError, Sendable {
  case timedOut(TimeInterval)
  case ioFailed

  var errorDescription: String? {
    switch self {
    case .timedOut(let seconds):
      "Délai dépassé (\(Int(seconds))s)."
    case .ioFailed:
      "Impossible de préparer les fichiers de sortie du process."
    }
  }
}
