import Foundation

/// **Une CLI installée n'est pas une CLI connectée.** Le binaire prouve
/// l'installation ; l'abonnement, lui, se prouve par la trace que le `login`
/// de chaque CLI laisse sur le disque. Sans cette trace, le premier tour
/// remonte une erreur brute d'authentification — vu en vrai avec `codex` et
/// `grok` : tout était « prêt », et rien ne répondait.
///
/// Ici parce que l'app (catalogue de ce Mac) et l'agent (scan de sa machine)
/// posent la même question et ne partagent que ce module. Pure : le lecteur
/// de fichier s'injecte, donc ça s'éprouve sans toucher `~`.
public enum EngineLogin {
  /// Ce qui prouve qu'une CLI est connectée, et le geste quand elle ne l'est pas.
  public struct Proof: Sendable, Equatable {
    /// Le fichier, relatif à `~`.
    public var file: String
    /// Une clé de premier niveau qui doit s'y trouver — `~/.claude.json`
    /// existe dès le premier lancement, mais `oauthAccount` n'y est qu'une
    /// fois connecté.
    public var jsonKey: String?
    /// Le geste, tel qu'on le dit dans une bulle ou sous une carte.
    public var gesture: String
  }

  static let claude = Proof(
    file: ".claude.json", jsonKey: "oauthAccount",
    gesture: "lance `claude` une fois dans un terminal et connecte-toi avec ton abonnement — jamais de clé."
  )
  static let codex = Proof(
    file: ".codex/auth.json", jsonKey: nil,
    gesture: "`codex login` dans un terminal — le compte ChatGPT, jamais de clé."
  )
  static let grok = Proof(
    file: ".grok/auth.json", jsonKey: nil,
    gesture: "`grok login` dans un terminal — l'abonnement SuperGrok ou X Premium, jamais de clé."
  )

  /// Par nom de moteur ou d'adaptateur. Un adaptateur se connecte par la CLI
  /// qu'il lance : `claude-code-acp` par `claude`, `codex-acp` par `codex`.
  /// Absent de la table : on ne sait pas dire, et on ne dit rien.
  public static let proofs: [String: Proof] = [
    "claude": claude,
    "claude-code-acp": claude,
    "codex": codex,
    "codex-acp": codex,
    "grok": grok,
  ]

  public static func gesture(for engine: String) -> String? { proofs[engine]?.gesture }

  /// `true` connecté, `false` pas connecté, `nil` : aucune preuve connue pour
  /// ce moteur — et « on ne sait pas » n'est pas « non ».
  public static func isLoggedIn(
    engine: String,
    home: String = NSHomeDirectory(),
    read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
  ) -> Bool? {
    guard let proof = proofs[engine] else { return nil }
    guard let data = read("\(home)/\(proof.file)") else { return false }
    guard let key = proof.jsonKey else { return true }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return object[key] != nil
  }
}
