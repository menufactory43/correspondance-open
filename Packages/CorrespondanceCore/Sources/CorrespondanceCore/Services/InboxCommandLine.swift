import Foundation

/// La ligne de commande de l'inbox, traduite en appel d'outil.
///
/// `correspondance-cli` et `correspondance-mcp` sont deux portes sur le même
/// cœur (`MCPInboxTools`) : ici on ne fait que lire les mots d'un shell et
/// les ranger dans le nom d'outil et les arguments que le serveur MCP
/// recevrait d'un modèle. Rien n'est décidé ici — ni la permission d'envoyer
/// (c'est `MCPInbox`), ni ce que l'outil fait.
///
/// Les sous-commandes sont en français, avec un alias anglais chacune : un
/// script écrit d'un côté ou de l'autre de la Manche marche pareil.
public enum InboxCommandLine {
  public enum Invocation {
    case help
    case version
    case doctor
    case tools
    case usage(String)
    case call(tool: String, arguments: [String: Any])
  }

  public struct Options: Sendable, Equatable {
    /// Sortie en JSON (`{"outil","ok","texte"}`) plutôt qu'en texte.
    public var json = false
    public init(json: Bool = false) { self.json = json }
  }

  public static let usage = """
    correspondance-cli — l'inbox de Correspondance en ligne de commande

      correspondance-cli file                            ce qui attend une réponse
      correspondance-cli lire <conversation> [--limite N] les derniers messages (20)
      correspondance-cli chercher <texte…>               cherche dans les conversations
      correspondance-cli archiver <conversation> [--annuler]
      correspondance-cli rappel <conversation> --dans <minutes> | --a <ISO 8601>
      correspondance-cli brouillon <conversation> [texte…]  pose un brouillon dans l'app
      correspondance-cli envoyer <conversation> [texte…]    envoie vraiment (liste blanche)
      correspondance-cli outil <nom> [arguments JSON]    n'importe quel outil, comme en MCP
      correspondance-cli outils                          la liste des outils et leur régime
      correspondance-cli --doctor                        dit s'il sait joindre le Relais

    Sans texte, brouillon et envoyer lisent l'entrée standard.
    --json rend {"outil","ok","texte"} ; le code de sortie dit la même chose
    (0 fait, 1 refusé ou en erreur, 2 mauvaise commande, 3 pas de session).

    La session vient de l'amorce de l'agent (~/.correspondance-agent/config.json)
    ou de CORRESPONDANCE_MCP_CONFIG. L'envoi n'est permis que dans les conversations
    listées dans CORRESPONDANCE_MCP_SEND (séparées par des virgules) — sinon on
    propose un brouillon.
    """

  /// Lit les mots après le nom du programme. `stdin` n'est appelé que si un
  /// texte manque là où il en faut un.
  public static func parse(
    _ arguments: [String],
    stdin: () -> String? = { nil }
  ) -> (Invocation, Options) {
    var options = Options()
    var mots: [String] = []
    for mot in arguments {
      switch mot {
      case "--json": options.json = true
      case "-h", "--help", "aide", "help": return (.help, options)
      case "--version", "version": return (.version, options)
      case "--doctor", "doctor": return (.doctor, options)
      default: mots.append(mot)
      }
    }
    guard let commande = mots.first else { return (.help, options) }
    let reste = Array(mots.dropFirst())

    func conversation() -> String? {
      guard let premiere = reste.first, premiere.hasPrefix("!") else { return nil }
      return premiere
    }
    func texte(apres: Int) -> String? {
      let libre = reste.dropFirst(apres).joined(separator: " ")
      if !libre.isEmpty, libre != "-" { return libre }
      guard let lu = stdin()?.trimmingCharacters(in: .whitespacesAndNewlines), !lu.isEmpty else { return nil }
      return lu
    }
    func valeur(_ drapeaux: [String]) -> String? {
      guard let index = reste.firstIndex(where: { drapeaux.contains($0) }), index + 1 < reste.count else { return nil }
      return reste[index + 1]
    }

    switch commande {
    case "file", "queue":
      return (.call(tool: "list_queue", arguments: [:]), options)

    case "lire", "read":
      guard let conv = conversation() else { return (.usage("lire : il manque la conversation (`!salon:serveur`)."), options) }
      var arguments: [String: Any] = ["conversation": conv]
      if let brut = valeur(["--limite", "--limit", "-n"]) {
        guard let limite = Int(brut), limite > 0 else { return (.usage("lire : --limite attend un nombre."), options) }
        arguments["limit"] = limite
      }
      return (.call(tool: "read_conversation", arguments: arguments), options)

    case "chercher", "search":
      let requete = reste.joined(separator: " ")
      guard !requete.isEmpty else { return (.usage("chercher : il manque ce qu'on cherche."), options) }
      return (.call(tool: "search", arguments: ["query": requete]), options)

    case "archiver", "archive":
      guard let conv = conversation() else { return (.usage("archiver : il manque la conversation."), options) }
      let annuler = reste.contains("--annuler") || reste.contains("--undo")
      return (.call(tool: "archive", arguments: ["conversation": conv, "on": !annuler]), options)

    case "rappel", "remind":
      guard let conv = conversation() else { return (.usage("rappel : il manque la conversation."), options) }
      var arguments: [String: Any] = ["conversation": conv]
      if let brut = valeur(["--dans", "--in"]) {
        guard let minutes = Int(brut), minutes > 0 else { return (.usage("rappel : --dans attend un nombre de minutes."), options) }
        arguments["in_minutes"] = minutes
      } else if let iso = valeur(["--a", "--à", "--at"]) {
        arguments["at"] = iso
      } else {
        return (.usage("rappel : dis quand, avec --dans <minutes> ou --a <ISO 8601>."), options)
      }
      return (.call(tool: "remind", arguments: arguments), options)

    case "brouillon", "draft":
      guard let conv = conversation() else { return (.usage("brouillon : il manque la conversation."), options) }
      guard let corps = texte(apres: 1) else { return (.usage("brouillon : il manque le texte (argument ou entrée standard)."), options) }
      return (.call(tool: "draft_reply", arguments: ["conversation": conv, "text": corps]), options)

    case "envoyer", "send":
      guard let conv = conversation() else { return (.usage("envoyer : il manque la conversation."), options) }
      guard let corps = texte(apres: 1) else { return (.usage("envoyer : il manque le texte (argument ou entrée standard)."), options) }
      return (.call(tool: "send_message", arguments: ["conversation": conv, "text": corps]), options)

    case "outil", "tool":
      guard let nom = reste.first else { return (.usage("outil : il manque le nom de l'outil."), options) }
      var arguments: [String: Any] = [:]
      if reste.count > 1 {
        let brut = reste.dropFirst().joined(separator: " ")
        guard let data = brut.data(using: .utf8),
              let objet = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (.usage("outil : les arguments doivent être un objet JSON."), options) }
        arguments = objet
      }
      return (.call(tool: nom, arguments: arguments), options)

    case "outils", "tools":
      return (.tools, options)

    default:
      return (.usage("commande inconnue : \(commande)"), options)
    }
  }

  /// La ligne JSON de `--json`. Une par appel, jamais plus.
  public static func jsonLine(tool: String, outcome: MCPInboxTools.Outcome) -> String {
    let objet: [String: Any] = ["outil": tool, "ok": !outcome.isError, "texte": outcome.text]
    guard let data = try? JSONSerialization.data(withJSONObject: objet, options: [.sortedKeys]),
          let ligne = String(data: data, encoding: .utf8)
    else { return "{}" }
    return ligne
  }
}
