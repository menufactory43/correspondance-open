import Foundation

/// **Installer un moteur depuis les réglages.** Le catalogue disait « pas un
/// bouton qui mentirait » : le bouton existe maintenant parce qu'il ne promet
/// que ce qu'il fait — lancer la commande épinglée dans un shell de connexion,
/// rendre sa sortie, et laisser le scan constater le résultat. Il n'affirme
/// jamais « installé » : c'est le binaire sur le disque qui le dira.
///
/// Un shell de connexion (`zsh -lc`) parce que `npm` et `brew` vivent dans un
/// PATH que l'app n'hérite pas.
enum EngineInstaller {
  struct Failure: LocalizedError {
    var commande: String
    var sortie: String
    var errorDescription: String? {
      let queue = sortie.split(separator: "\n").suffix(6).joined(separator: "\n")
      return "« \(commande) » n'est pas passée.\n\(queue.isEmpty ? "(aucune sortie)" : queue)"
    }
  }

  /// Ne se lance que ce qu'on sait lire : une installation npm ou brew. Un
  /// `curl | bash` se copie, il ne se clique pas.
  static func estLancable(_ commande: String) -> Bool {
    commande.hasPrefix("npm install ") || commande.hasPrefix("brew install ")
  }

  /// La sortie complète (stdout et stderr mêlés), ou l'échec avec sa sortie.
  static func installer(_ commande: String, timeout: TimeInterval = 600) async throws -> String {
    precondition(estLancable(commande))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", commande]
    let tuyau = Pipe()
    process.standardOutput = tuyau
    process.standardError = tuyau

    // Lecture bloquante dans une tâche à part : lire jusqu'à la fin **avant**
    // d'attendre la sortie, sinon un npm bavard remplit le tuyau et s'endort.
    return try await Task.detached(priority: .userInitiated) { () throws -> String in
      do { try process.run() } catch {
        throw Failure(commande: commande, sortie: error.localizedDescription)
      }
      let garde = Task {
        try? await Task.sleep(for: .seconds(timeout))
        if process.isRunning { process.terminate() }
      }
      let data = tuyau.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      garde.cancel()
      let sortie = String(data: data, encoding: .utf8) ?? ""
      guard process.terminationStatus == 0 else { throw Failure(commande: commande, sortie: sortie) }
      return sortie
    }.value
  }
}
