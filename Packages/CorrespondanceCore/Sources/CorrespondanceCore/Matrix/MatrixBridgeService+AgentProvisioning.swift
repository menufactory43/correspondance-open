import CorrespondanceMatrixClient
import Foundation

/// « Activer cc » : créer le compte du bot sur le Relais et rendre son amorce.
///
/// C'est ce qui remplace le `register_new_matrix_user` en SSH du montage
/// artisanal. Trois précautions, et elles ne sont pas décoratives :
/// vérifier qu'on est bien administrateur **avant** de promettre ; ne jamais
/// déconnecter les sessions existantes (`logout_devices: false`) ; ne pas
/// réinitialiser le mot de passe d'un bot qui tourne déjà ailleurs.
extension MatrixBridgeService {

  /// L'amorce d'un agent : les trois lignes que sa machine doit connaître.
  /// Tout le reste vient de sa room console.
  public struct AgentBootstrap: Sendable, Equatable {
    public var homeserver: URL
    public var user: String
    public var password: String
    public var owner: String

    /// Le `config.json` minimal, tel qu'on le pose sur l'hôte (ou qu'on
    /// l'affiche à coller sur un hôte distant).
    public func configJSON() -> String {
      let escaped = { (text: String) in
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      }
      return """
        {
          "homeserver": "\(escaped(homeserver.absoluteString))",
          "user": "\(escaped(user))",
          "password": "\(escaped(password))",
          "owners": ["\(escaped(owner))"]
        }
        """
    }
  }

  public enum AgentProvisioningError: LocalizedError, Equatable {
    case notServerAdmin
    case notConnected
    /// Un agent tourne déjà ailleurs sur ce compte. Deux agents, ce sont deux
    /// réponses : on refuse, et on dit où est le premier.
    case agentDejaVivant(hote: String)
    /// Les identifiants qu'on s'apprêtait à écrire ne marchent pas. On ne pose
    /// **jamais** une amorce qu'on n'a pas essayée : l'agent partirait en
    /// boucle démarrage/arrêt, ce qui ressemble à un plantage sans en être un.
    case identifiantsRefuses(detail: String)

    public var errorDescription: String? {
      switch self {
      case .notServerAdmin:
        "ce compte n'est pas administrateur du Relais — c'est lui qui crée les comptes des agents"
      case .notConnected:
        "pas encore connecté au Relais"
      case .agentDejaVivant(let hote):
        "cc tourne déjà sur « \(hote) ». Deux agents sur le même compte répondraient deux fois — "
          + "arrête celui-là avant d'en activer un ici."
      case .identifiantsRefuses(let detail):
        "le Relais refuse les identifiants de cc (\(detail)). Rien n'a été installé — "
          + "le compte existe peut-être avec un autre mot de passe."
      }
    }
  }

  /// Vérifie le pouvoir avant de promettre quoi que ce soit.
  public func canProvisionAgents() async -> Bool {
    guard isConnected else { return false }
    return await client.isServerAdmin(userID: currentUserID)
  }

  /// Crée (ou retrouve) le compte de l'agent et rend son amorce.
  ///
  /// Quatre étapes, et aucune ne suppose le résultat de la précédente. C'est la
  /// leçon d'un vrai incident : l'app avait écrit une amorce avec un mot de
  /// passe qu'elle n'avait **jamais posé sur le serveur** — le compte existait
  /// déjà, le secret venait d'un autre Relais, et l'agent tournait en boucle
  /// « démarre, refusé, redémarre ».
  ///
  /// 1. **Un agent vit-il ailleurs ?** Un status de moins de deux minutes venu
  ///    d'une autre machine : on refuse, en nommant l'hôte.
  /// 2. **Le compte existe-t-il ?** S'il existe et qu'aucun agent ne vit, on
  ///    repose un mot de passe neuf — `logout_devices: false`, donc les
  ///    sessions survivent — et on l'écrit dans le journal. C'est un choix, pas
  ///    un silence.
  /// 3. **Les identifiants marchent-ils ?** On se connecte une fois. C'est la
  ///    seule preuve qui vaille.
  /// 4. Alors seulement, l'amorce.
  public func provisionAgent(named agent: String) async throws -> AgentBootstrap {
    guard isConnected else { throw AgentProvisioningError.notConnected }
    guard await client.isServerAdmin(userID: currentUserID) else {
      throw AgentProvisioningError.notServerAdmin
    }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    guard let homeserver = await client.currentCredentials?.homeserver else {
      throw AgentProvisioningError.notConnected
    }

    // 1. Un agent vivant ailleurs ? Le plan le prévoyait depuis le premier
    //    jour ; c'est aussi ce qui évite tout le détour ci-dessous.
    if let ailleurs = await liveAgentElsewhere(named: agent) {
      throw AgentProvisioningError.agentDejaVivant(hote: ailleurs)
    }
    //    Le status ne suffit pas : un agent d'hier n'en publie aucun, et le
    //    silence a déjà été pris pour une absence — deux cc ont répondu.
    //    Le serveur, lui, voit chaque session à chaque /sync.
    if let session = await liveSessionElsewhere(named: agent) {
      throw AgentProvisioningError.agentDejaVivant(hote: session)
    }

    // 2. Le compte, et son mot de passe.
    let existe = await client.userExists(userID)
    var motDePasse = AgentSecretStore.password(for: agent)
    if !existe || motDePasse == nil {
      let neuf = AgentSecretStore.generatePassword()
      try await client.provisionUser(userID: userID, password: neuf, displayName: agent, admin: false)
      AgentSecretStore.save(password: neuf, for: agent)
      motDePasse = neuf
      print("agent : compte \(userID) — \(existe ? "mot de passe reposé" : "créé")")
    }
    guard var secret = motDePasse else {
      throw AgentProvisioningError.identifiantsRefuses(detail: "aucun mot de passe")
    }

    // 3. La preuve : on se connecte. Un secret retrouvé au Trousseau peut très
    //    bien venir d'un autre Relais — c'est exactement ce qui s'est produit.
    if await !credentialsWork(homeserver: homeserver, user: agent, password: secret) {
      // Le secret ne vaut rien ici : on en repose un, une fois, puis on
      // revérifie. Si ça échoue encore, on renonce sans rien écrire.
      let neuf = AgentSecretStore.generatePassword()
      do {
        try await client.provisionUser(userID: userID, password: neuf, displayName: agent, admin: false)
      } catch {
        throw AgentProvisioningError.identifiantsRefuses(detail: error.localizedDescription)
      }
      guard await credentialsWork(homeserver: homeserver, user: agent, password: neuf) else {
        throw AgentProvisioningError.identifiantsRefuses(detail: "le Relais refuse encore après réinitialisation")
      }
      AgentSecretStore.save(password: neuf, for: agent)
      secret = neuf
      print("agent : mot de passe de \(userID) reposé — l'ancien ne marchait plus")
    }

    // 4. Seulement maintenant.
    return AgentBootstrap(homeserver: homeserver, user: agent, password: secret, owner: currentUserID)
  }

  /// Les identifiants ouvrent-ils vraiment une session ? Un client jetable,
  /// pour ne pas toucher à la nôtre.
  private func credentialsWork(homeserver: URL, user: String, password: String) async -> Bool {
    let essai = MatrixClient(credentials: nil)
    do {
      _ = try await essai.login(homeserver: homeserver, user: user, password: password)
      return true
    } catch {
      return false
    }
  }

  /// Un agent de ce nom tourne-t-il sur une **autre** machine ? Rend le nom de
  /// l'hôte, s'il s'est annoncé il y a moins de deux minutes.
  ///
  /// C'est le status que l'agent poste dans sa console : il porte sa machine et
  /// son pid depuis qu'on refuse de démarrer à deux.
  public func liveAgentElsewhere(named agent: String) async -> String? {
    guard let roomID = try? await findAgentConsole(agent: agent) else { return nil }
    let agentID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    guard let messages = try? await client.roomMessages(roomID: roomID, limit: 40) else { return nil }
    let ici = AgentWire.hostName
    for event in messages.chunk
    where event.type == AgentWire.statusType && event.sender == agentID {
      guard let hote = event.content?.value(at: AgentWire.StatusKey.host)?.stringValue else { continue }
      guard hote != ici else { return nil }  // c'est nous, ou notre propre cadavre
      guard Date().timeIntervalSince(event.sentAt) < 120 else { return nil }
      return hote
    }
    return nil
  }

  /// Une session de cet agent, vue par le serveur il y a moins de quinze
  /// minutes, qui n'est pas celle de cette machine ? Rend de quoi la nommer.
  public func liveSessionElsewhere(named agent: String, now: Date = Date()) async -> String? {
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    guard let devices = try? await client.userDevices(userID: userID) else { return nil }
    return AgentSessions.elsewhere(devices, here: AgentWire.hostName, now: now)
  }

  /// Le compte de cet agent existe-t-il déjà, et connaît-on son secret ?
  /// L'écran s'en sert pour dire « déjà créé » plutôt que de proposer une
  /// activation qui changerait un mot de passe pour rien.
  public func agentAccountState(named agent: String) async -> (exists: Bool, secretKnown: Bool) {
    guard isConnected else { return (false, false) }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    return (await client.userExists(userID), AgentSecretStore.password(for: agent) != nil)
  }
}

/// La décision « un agent vit ailleurs », prise sur les sessions que le serveur
/// rapporte. Pure, pour être éprouvée sans Relais.
public enum AgentSessions {
  /// Au-delà, une session est un cadavre. Un agent vivant fait un `/sync`
  /// toutes les 30 s, mais Synapse n'écrit `last_seen` qu'une fois par
  /// **dix minutes** (`LAST_SEEN_GRANULARITY`) — mesuré : un cc vivant « vu il y
  /// a 223 s ». Plus court que ça, la garde prendrait un vivant pour un mort.
  public static let silenceMax: TimeInterval = 15 * 60

  /// La première session vivante qui n'est pas de cette machine, décrite pour
  /// l'erreur : « Correspondance agent · umbrel, vue il y a 37 s ».
  public static func elsewhere(_ devices: [MatrixClient.UserDevice], here: String, now: Date) -> String? {
    let mine = MatrixClient.agentDeviceDisplayName(host: here)
    for device in devices {
      guard let seen = device.lastSeen else { continue }
      let age = now.timeIntervalSince(seen)
      guard age >= 0, age < silenceMax else { continue }
      if device.displayName == mine { continue }
      let nom = device.displayName ?? "session \(device.deviceID)"
      return "\(nom), vue il y a \(Int(age)) s"
    }
    return nil
  }
}
