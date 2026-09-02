import CorrespondanceMatrixClient
import Foundation

/// **Le catalogue des moteurs de ce Mac** : ce avec quoi un agent peut penser
/// ici, et dans quel état.
///
/// Pourquoi ce fichier existe dans la cible Mac plutôt que dans Core : Core est
/// partagé avec iOS, et `Process` n'y existe pas. Pourquoi il ne réutilise pas
/// `EngineScan` de l'AgentKit : l'app ne dépend pas de l'AgentKit non plus. Les
/// chemins de détection sont donc redits ici — les mêmes que `Subprocess.find`,
/// `~/.local/bin` compris, parce que l'installeur d'Hermes pose son binaire là,
/// hors du PATH de la plupart des shells non-login. Le `PATH` d'un enfant de
/// l'app n'est pas celui d'un terminal : `which` seul mentirait.
///
/// **Ce catalogue ne parle que de cette machine.** Les moteurs d'un hôte
/// distant se lisent dans le status de l'agent qui y tourne
/// (`AgentStatus.engines`), jamais ici : les moteurs vivent là où l'agent
/// tourne, pas là où l'app tourne.
enum EngineCatalog {

  /// La version de l'adaptateur ACP que l'installation pose
  /// (`infra/agent/install.sh`, `ACP_PACKAGE`). Elle est épinglée parce que le
  /// **régime de permission par défaut d'un adaptateur change d'une version à
  /// l'autre** — `claude-agent-acp` 0.70.0 démarrait en mode `auto` et a
  /// exécuté un `Bash` sans rien demander (cf. `docs/SPIKE-acp.md`). Un
  /// adaptateur d'une autre version n'est donc pas « prêt » : il est d'une
  /// version qu'on n'a pas éprouvée, et on le dit.
  ///
  /// Un test tient cette constante contre le script : deux endroits qui
  /// divergent au premier `npm update` seraient pires qu'un seul.
  static let acpVersionEpinglee = "0.16.2"

  /// Le nom court de cette machine — `umbrel`, pas `umbrel.local`. C'est le
  /// même calcul que celui de l'agent (`AgentWire.hostName`) : sans lui, on ne
  /// saurait pas reconnaître « sur ce Mac » dans le status d'un agent.
  static var nomDeCeMac: String {
    let nom = ProcessInfo.processInfo.hostName
    return nom.split(separator: ".").first.map(String.init) ?? nom
  }

  /// Comment un agent pense : ce qui va dans `AgentConsoleConfig.backend`.
  enum Backend: String, Sendable {
    case claude
    case hermes
    case acp
  }

  /// Une entrée du catalogue. Ce qu'on cherche, ce qu'on en dit, ce qu'on
  /// propose quand ça manque.
  struct Entry: Sendable, Equatable, Identifiable {
    /// L'identifiant du moteur — c'est aussi le nom du binaire cherché.
    var id: String
    var labelFR: String
    /// Le backend que l'agent devra écrire dans sa console.
    var backend: Backend
    /// Pour un backend `acp`, la commande de l'adaptateur (`acpCommand`).
    var acpCommand: String?
    /// Ses arguments : `grok agent stdio`, `goose acp`. Un adaptateur dédié
    /// n'en a pas ; une CLI complète, sans eux, ouvre son interface et attend.
    var acpArguments: [String] = []
    /// Le nom d'agent proposé quand on l'active. Modifiable dans l'écran :
    /// c'est une proposition, pas une contrainte.
    var nomAgentPropose: String
    /// Ce qu'on affiche quand le moteur manque : la commande, et le geste de
    /// connexion qui suit.
    var indiceInstallation: String
    /// La commande que le bouton « Installer » lance — npm ou brew seulement,
    /// `EngineInstaller.estLancable`. `nil` : ça se copie, ça ne se clique pas.
    var commandeInstallation: String? = nil
    /// La version épinglée, pour les adaptateurs ACP seulement.
    var versionEpinglee: String?

    var estAdaptateurACP: Bool { backend == .acp }
  }

  /// L'état d'un moteur sur cette machine. Chaque cas vient d'une **preuve** :
  /// un fichier exécutable trouvé, une sortie de `--version` lue.
  enum State: Sendable, Equatable {
    /// Trouvé, et à la version qu'on sait faire marcher.
    case pret(version: String?)
    /// Aucun binaire à aucun des chemins connus.
    case nonInstalle
    /// Trouvé, mais pas à la version épinglée. Ce n'est pas « cassé » : c'est
    /// « on n'a pas éprouvé ce régime de permission », et ça se dit.
    case adaptateurPerime(version: String, epinglee: String)
    /// Trouvé, à la bonne version, mais sa trace de connexion manque : le
    /// premier tour échouerait sur une erreur d'authentification. Le geste
    /// est celui de `EngineLogin`.
    case nonConnecte(geste: String)

    var estPret: Bool { if case .pret = self { return true } else { return false } }

    var labelFR: String {
      switch self {
      case .pret(let version):
        version.map { "prêt — \($0)" } ?? "prêt"
      case .nonInstalle:
        "pas installé sur ce Mac"
      case .adaptateurPerime(let version, let epinglee):
        "version \(version) — l'installation en pose \(epinglee), "
          + "et le régime de permission d'un adaptateur change d'une version à l'autre"
      case .nonConnecte:
        "installé, mais pas connecté"
      }
    }
  }

  /// Un moteur du catalogue avec ce qu'on a constaté de lui.
  struct Finding: Sendable, Equatable, Identifiable {
    var entry: Entry
    var state: State
    /// Le chemin où on l'a trouvé — la preuve, affichable.
    var path: String?

    var id: String { entry.id }
  }

  // MARK: - Le catalogue

  static let entries: [Entry] = [
    Entry(
      id: "claude",
      labelFR: "Claude Code",
      backend: .claude,
      acpCommand: nil,
      nomAgentPropose: "cc",
      indiceInstallation: "npm install -g @anthropic-ai/claude-code, puis `claude` une fois "
        + "pour ouvrir la session — l'abonnement, jamais de clé.",
      commandeInstallation: "npm install -g @anthropic-ai/claude-code",
      versionEpinglee: nil
    ),
    Entry(
      id: "hermes",
      labelFR: "Hermes",
      backend: .hermes,
      acpCommand: nil,
      nomAgentPropose: "hermes",
      indiceInstallation: "L'installeur d'Hermes (hermes-agent.nousresearch.com) pose son binaire "
        + "dans ~/.local/bin. Ses outils se règlent chez lui (`hermes tools`), pas ici : "
        + "configure-le serré avant de l'inviter où que ce soit.",
      versionEpinglee: nil
    ),
    Entry(
      id: "claude-code-acp",
      labelFR: "Claude Code (ACP)",
      backend: .acp,
      acpCommand: "claude-code-acp",
      nomAgentPropose: "claude",
      indiceInstallation: "npm install -g @zed-industries/claude-code-acp@\(acpVersionEpinglee)",
      commandeInstallation: "npm install -g @zed-industries/claude-code-acp@\(acpVersionEpinglee)",
      versionEpinglee: acpVersionEpinglee
    ),
    // Éprouvé le 2 septembre 2026 : `codex-acp` 1.8.0 parle ACP sur le compte
    // ChatGPT de `codex login`, sans clé (cf. `docs/SPIKE-acp.md`).
    Entry(
      id: "codex-acp",
      labelFR: "Codex (ACP)",
      backend: .acp,
      acpCommand: "codex-acp",
      nomAgentPropose: "codex",
      indiceInstallation: "npm install -g @agentclientprotocol/codex-acp, puis `codex login` une fois "
        + "— le compte ChatGPT, jamais de clé.",
      commandeInstallation: "npm install -g @agentclientprotocol/codex-acp",
      versionEpinglee: nil
    ),
    // Éprouvé le même jour : `grok agent stdio` parle ACP sur le compte de
    // `grok login` (SuperGrok ou X Premium), sans clé.
    Entry(
      id: "grok",
      labelFR: "Grok Build (ACP)",
      backend: .acp,
      acpCommand: "grok",
      acpArguments: ["agent", "stdio"],
      nomAgentPropose: "grok",
      indiceInstallation: "curl -fsSL https://x.ai/cli/install.sh | bash, puis `grok login` une fois "
        + "— l'abonnement SuperGrok ou X Premium, jamais de clé.",
      versionEpinglee: nil
    ),
    Entry(
      id: "goose",
      labelFR: "Goose (ACP)",
      backend: .acp,
      acpCommand: "goose",
      acpArguments: ["acp"],
      nomAgentPropose: "goose",
      indiceInstallation: "brew install block-goose-cli — puis `goose acp` sert d'adaptateur.",
      commandeInstallation: "brew install block-goose-cli",
      versionEpinglee: nil
    ),
    // Pas de Gemini : le 2 septembre 2026, `gemini --acp` connecté à un compte
    // Google personnel répond « This client is no longer supported for Gemini
    // Code Assist for individuals » et renvoie vers Antigravity. Sans
    // abonnement qui passe, pas d'entrée.
  ]

  // MARK: - Constater

  /// Les chemins où on cherche, dans l'ordre. Le `PATH` d'un enfant de l'app
  /// n'est pas celui d'un shell de connexion : la découverte doit être la
  /// nôtre (`docs/PLAN-relais-agents.md`, § « Récupérer les abonnements »).
  static func cheminsCandidats(_ name: String, home: String = NSHomeDirectory()) -> [String] {
    ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
     "/usr/bin/\(name)"]
  }

  /// La conclusion, à partir de ce qu'on a **vu** : un chemin exécutable, une
  /// ligne de version. Pure, donc éprouvée sans lancer un seul processus —
  /// c'est elle qui empêche l'écran d'affirmer « prêt » sans preuve.
  ///
  /// `connecte` : la trace de connexion de la CLI (`EngineLogin`). `nil` quand
  /// on n'a pas de preuve pour ce moteur — et « on ne sait pas » ne retire
  /// pas le « prêt ». `false` le retire : un premier tour sans connexion
  /// n'est qu'une erreur brute.
  static func decide(entry: Entry, path: String?, version: String?, connecte: Bool? = nil) -> State {
    guard path != nil else { return .nonInstalle }
    if connecte == false, let geste = EngineLogin.gesture(for: entry.acpCommand ?? entry.id) {
      return .nonConnecte(geste: geste)
    }
    guard let epinglee = entry.versionEpinglee else { return .pret(version: version) }
    guard let version, let lue = numeroDeVersion(version) else {
      // Trouvé, mais il n'a pas su dire sa version : on ne peut pas affirmer
      // qu'elle est la bonne, on ne peut pas affirmer qu'elle ne l'est pas.
      // On le dit comme « périmé » plutôt que « prêt » : c'est le sens strict —
      // ce régime de permission n'a pas été éprouvé.
      return .adaptateurPerime(version: version ?? "version inconnue", epinglee: epinglee)
    }
    return lue == epinglee ? .pret(version: version) : .adaptateurPerime(version: lue, epinglee: epinglee)
  }

  /// Le numéro dans une ligne de version : `claude-code-acp 0.16.2` → `0.16.2`.
  /// Les CLI n'ont aucun format commun, et un `nil` vaut mieux qu'une
  /// comparaison sur une phrase entière.
  static func numeroDeVersion(_ ligne: String) -> String? {
    let morceaux = ligne.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    for morceau in morceaux {
      let nettoye = morceau.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
      let parts = nettoye.split(separator: ".")
      if parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nettoye }
    }
    return nil
  }

  /// Le catalogue confronté à cette machine. `which` et `version` sont
  /// injectables : les tests éprouvent la décision sans dépendre de ce qui est
  /// installé sur la machine qui les fait tourner.
  static func scan(
    entries liste: [Entry] = entries,
    which: (String) -> String? = Self.trouver,
    version: (String) -> String? = { Self.versionDepuisPackageJSON($0) ?? Self.versionDe($0) },
    connecte: (String) -> Bool? = { EngineLogin.isLoggedIn(engine: $0) }
  ) -> [Finding] {
    liste.map { entry in
      let binaire = entry.acpCommand ?? entry.id
      let path = which(binaire)
      let ligne = path.flatMap { version($0) }
      let state = decide(entry: entry, path: path, version: ligne, connecte: path == nil ? nil : connecte(binaire))
      return Finding(entry: entry, state: state, path: path)
    }
  }

  /// Le binaire, **constaté sur le disque**. Rien d'autre ne prouve qu'il est là.
  static func trouver(_ name: String) -> String? {
    let manager = FileManager.default
    if let found = cheminsCandidats(name).first(where: { manager.isExecutableFile(atPath: $0) }) {
      return found
    }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
      let candidate = "\(dir)/\(name)"
      if manager.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// La version d'un paquet npm, lue dans son `package.json` : `npm install -g`
  /// pose un lien `/opt/homebrew/bin/claude-code-acp` vers
  /// `…/node_modules/@zed-industries/claude-code-acp/dist/index.js`, et le
  /// `package.json` est un ou deux dossiers au-dessus.
  ///
  /// Pourquoi ne pas se contenter de `--version` : un adaptateur ACP est un
  /// serveur JSON-RPC sur stdin — `claude-code-acp --version` ne répond rien
  /// et attend. On le tuait après cinq secondes et on concluait « version
  /// inconnue », donc « pas prêt » — avec le bon paquet installé à la bonne
  /// version. Le fichier sur le disque est une meilleure preuve qu'un
  /// processus muet.
  static func versionDepuisPackageJSON(_ path: String, maxNiveaux: Int = 4) -> String? {
    let resolu = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var dossier = resolu.deletingLastPathComponent()
    for _ in 0..<maxNiveaux {
      let candidat = dossier.appendingPathComponent("package.json")
      if let data = try? Data(contentsOf: candidat), let version = versionDansPackageJSON(data) {
        return version
      }
      let parent = dossier.deletingLastPathComponent()
      if parent.path == dossier.path { break }
      dossier = parent
    }
    return nil
  }

  /// Le champ `version` d'un `package.json`. Pure, donc éprouvée.
  static func versionDansPackageJSON(_ data: Data) -> String? {
    guard let objet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = objet["version"] as? String, !version.isEmpty
    else { return nil }
    return version
  }

  /// `<binaire> --version`, borné : un moteur qui ne répond pas ne doit pas
  /// figer l'écran des réglages.
  static func versionDe(_ path: String, timeout: TimeInterval = 5) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let tuyau = Pipe()
    process.standardOutput = tuyau
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }

    let echeance = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < echeance { usleep(50_000) }
    if process.isRunning {
      process.terminate()
      return nil
    }
    let data = (try? tuyau.fileHandleForReading.readToEnd()) ?? Data()
    let texte = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (texte?.isEmpty ?? true) ? nil : texte
  }
}
