import CorrespondanceMatrixClient
import Foundation

/// Ce que l'agent doit retenir entre deux lancements : sa session Matrix, où
/// il en était du `/sync`, et la session Claude de chaque room — c'est elle qui
/// donne à « cc » une mémoire par conversation.
///
/// Fichier JSON, pas Trousseau : le bot tourne sans session graphique, et un
/// jour sous Linux. Le fichier est en `0600`.
public struct AgentState: Codable, Sendable, Equatable {
  public var credentials: MatrixCredentials?
  public var nextBatch: String?
  /// `session_id` Claude Code par room.
  public var claudeSessions: [String: String] = [:]

  public init() {}

  public static func load(from url: URL) -> AgentState {
    guard let data = try? Data(contentsOf: url),
          let state = try? JSONDecoder().decode(AgentState.self, from: data)
    else { return AgentState() }
    return state
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
  }
}
