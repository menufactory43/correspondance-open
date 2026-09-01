import CorrespondanceMatrixClient
import Foundation

/// L'Agent Client Protocol — la couture standard entre un harnais (nous) et un
/// moteur (Claude Code, Codex, goose). Du JSON-RPC 2.0 en lignes sur stdio.
///
/// Ce fichier ne lance aucun processus : il encode les requêtes et lit les
/// réponses. C'est ce que les tests exercent ; `ACPBackend` n'ajoute que le tuyau.
///
/// Éprouvé dans `docs/SPIKE-acp.md` : `initialize` → `session/new` (ou
/// `session/load`) → `session/set_mode` → `session/prompt`, l'abonnement de la
/// machine suffit, et la reprise survit au changement de processus.
public enum ACP {

  /// Ce qui arrive du moteur. Une ligne, un message.
  public enum Incoming: Sendable, Equatable {
    /// La réponse à une de nos requêtes.
    case result(id: Int, value: MatrixJSON)
    case failure(id: Int, message: String)
    /// Une requête du moteur vers nous : permission, lecture de fichier…
    case request(id: MatrixJSON, method: String, params: MatrixJSON)
    /// Un `session/update` : réponse progressive, appel d'outil, jetons consommés.
    case notification(method: String, params: MatrixJSON)
    /// Une ligne que le moteur écrit sans que ce soit du JSON-RPC (bruit de démarrage).
    case noise(String)
  }

  public static func parse(line: String) -> Incoming {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
          let json = try? JSONDecoder().decode(MatrixJSON.self, from: data),
          case .object = json
    else { return .noise(trimmed) }

    let method = json["method"]?.stringValue
    let id = json["id"]

    if let method {
      // Une requête a un id, une notification n'en a pas.
      if let id { return .request(id: id, method: method, params: json["params"] ?? .object([:])) }
      return .notification(method: method, params: json["params"] ?? .object([:]))
    }
    guard let numericID = id?.intValue else { return .noise(trimmed) }
    if let error = json["error"] {
      let message = error["message"]?.stringValue ?? "erreur sans message"
      let details = error.value(at: "data.details")?.stringValue
      return .failure(id: numericID, message: details.map { "\(message) — \($0)" } ?? message)
    }
    return .result(id: numericID, value: json["result"] ?? .object([:]))
  }

  // MARK: - Ce qu'on envoie

  /// Une ligne JSON-RPC prête à écrire sur stdin, saut de ligne compris.
  public static func encode(_ json: MatrixJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(json), let text = String(data: data, encoding: .utf8) else {
      return "{}\n"
    }
    return text + "\n"
  }

  public static func request(id: Int, method: String, params: MatrixJSON) -> String {
    encode(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
  }

  public static func response(id: MatrixJSON, result: MatrixJSON) -> String {
    encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
  }

  /// On n'annonce pas de capacité fichier : le moteur a les siennes, et on ne
  /// veut pas devenir son système de fichiers.
  public static func initializeRequest(id: Int) -> String {
    request(id: id, method: "initialize", params: .object([
      "protocolVersion": .number(1),
      "clientCapabilities": .object([
        "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)])
      ]),
    ]))
  }

  public static func sessionNewRequest(id: Int, cwd: String) -> String {
    request(id: id, method: "session/new", params: .object([
      "cwd": .string(cwd), "mcpServers": .array([]),
    ]))
  }

  /// La mémoire d'une conversation : on reprend la session du tour précédent.
  public static func sessionLoadRequest(id: Int, sessionID: String, cwd: String) -> String {
    request(id: id, method: "session/load", params: .object([
      "sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([]),
    ]))
  }

  /// **Le mode se force, il ne se subit jamais.** `claude-agent-acp` 0.70.0
  /// démarre en `auto` — un classifieur décide à notre place et a lancé un
  /// `Bash` sans rien demander (cf. `docs/SPIKE-acp.md`). Qu'on veuille tout
  /// autoriser ne change rien à la règle : c'est nous qui posons le régime.
  public static func setModeRequest(id: Int, sessionID: String, mode: String) -> String {
    request(id: id, method: "session/set_mode", params: .object([
      "sessionId": .string(sessionID), "modeId": .string(mode),
    ]))
  }

  public static func promptRequest(id: Int, sessionID: String, text: String) -> String {
    request(id: id, method: "session/prompt", params: .object([
      "sessionId": .string(sessionID),
      "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ]))
  }

  /// Le bouton « Arrêter » d'un tour qui dure.
  public static func cancelNotification(sessionID: String) -> String {
    encode(.object([
      "jsonrpc": .string("2.0"), "method": .string("session/cancel"),
      "params": .object(["sessionId": .string(sessionID)]),
    ]))
  }

  // MARK: - Ce qu'on répond au moteur

  /// **Pleine permission.** Un agent invité par son propriétaire a ses outils :
  /// on choisit l'option la plus permissive que le moteur propose, et
  /// `allow_always` d'abord pour ne pas être rappelé à chaque appel du tour.
  /// Ce qui borne le risque est ailleurs — le dossier de la room, les
  /// propriétaires seuls, le journal (cf. `docs/PLAN-relais-agents.md`).
  public static func grantedOption(in params: MatrixJSON) -> String? {
    let options = params["options"]?.arrayValue ?? []
    let ranked = ["allow_always", "allow_once"]
    for kind in ranked {
      if let match = options.first(where: { $0["kind"]?.stringValue == kind }) {
        return match["optionId"]?.stringValue
      }
    }
    // Un moteur qui nomme ses options autrement : on prend ce qui autorise.
    if let match = options.first(where: { ($0["optionId"]?.stringValue ?? "").hasPrefix("allow") }) {
      return match["optionId"]?.stringValue
    }
    return options.first?["optionId"]?.stringValue
  }

  public static func permissionResponse(id: MatrixJSON, params: MatrixJSON) -> String {
    guard let optionID = grantedOption(in: params) else {
      return response(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
    }
    return response(id: id, result: .object([
      "outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])
    ]))
  }

  /// Ce qu'on répond à une requête du moteur qu'on ne sait pas honorer : un
  /// résultat vide plutôt qu'un silence, qui bloquerait son tour.
  public static func emptyResponse(id: MatrixJSON) -> String {
    response(id: id, result: .object([:]))
  }

  // MARK: - Ce qu'on lit dans un `session/update`

  /// Le texte de la réponse, morceau par morceau — de quoi éditer la bulle au
  /// fil de l'eau quand la réponse progressive arrivera.
  public static func messageChunk(in params: MatrixJSON) -> String? {
    guard let update = params["update"], update["sessionUpdate"]?.stringValue == "agent_message_chunk" else {
      return nil
    }
    return update.value(at: "content.text")?.stringValue
  }

  /// L'outil qu'un moteur vient d'employer — c'est la matière du journal des
  /// tours dans la room console : qui, quoi, quels outils.
  public static func toolCall(in params: MatrixJSON) -> String? {
    guard let update = params["update"], update["sessionUpdate"]?.stringValue == "tool_call" else { return nil }
    return update["title"]?.stringValue ?? update["kind"]?.stringValue
  }

  /// Les jetons consommés, quand le moteur les compte — le plafond horaire
  /// pourra devenir un plafond de jetons, mesuré au lieu d'être deviné.
  public static func totalTokens(in value: MatrixJSON) -> Int? {
    value.value(at: "usage.totalTokens")?.intValue
  }

  /// Le `sessionId` d'un `session/new`.
  public static func sessionID(in result: MatrixJSON) -> String? {
    result["sessionId"]?.stringValue
  }

  /// Les modes qu'un moteur annonce, et celui où il démarre. Le catalogue s'en
  /// sert pour dire, par version, ce qu'on force.
  public static func modes(in result: MatrixJSON) -> (current: String?, available: [String]) {
    let current = result.value(at: "modes.currentModeId")?.stringValue
    let available = (result.value(at: "modes.availableModes")?.arrayValue ?? [])
      .compactMap { $0["id"]?.stringValue }
    return (current, available)
  }
}
