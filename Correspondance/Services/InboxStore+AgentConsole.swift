import CorrespondanceCore
import Foundation

/// Ce que l'app fait de la room console d'un agent : l'ouvrir, y écrire les
/// réglages, y lire le status et le journal.
///
/// Rien ici ne parle à l'agent directement — on écrit sur le Relais, il relit à
/// son prochain `/sync`. C'est tout le sujet de la phase 1 : un réglage change
/// sans SSH et sans redémarrage.
extension InboxStore {

  /// Le nom **par défaut** proposé quand on n'en nomme aucun : le premier
  /// agent d'un Relais s'appelle `cc`. Rien ici ne le suppose unique — chaque
  /// geste prend son `agent:`, parce qu'un Relais en porte plusieurs, chacun
  /// avec son compte et sa console.
  var agentName: String { MatrixIdentity.agentName }

  /// Ce que la console raconte, ou `nil` si elle n'existe pas encore.
  func loadAgentConsole(agent: String? = nil) async -> MatrixBridgeService.AgentConsole? {
    do {
      return try await matrix.readAgentConsole(agent: agent ?? agentName)
    } catch {
      Self.relayLog.error("console de l'agent illisible : \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// **L'annuaire** : tous les agents que le Relais connaît, chacun avec sa
  /// console, sa config, son dernier status et son journal. C'est la source de
  /// vérité de « quels agents existent » — un agent qui tourne sur le NUC n'a
  /// jamais été activé depuis ce Mac, et il est là.
  func listAgentConsoles() async -> [MatrixBridgeService.AgentConsole] {
    do {
      return try await matrix.listAgentConsoles()
    } catch {
      Self.relayLog.error("annuaire des agents illisible : \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  /// Crée la console si elle manque et y écrit la configuration de départ —
  /// le geste de la première activation. L'agent est invité au passage ; il
  /// rejoint parce qu'un propriétaire l'a invité, et découvre sa config seul.
  @discardableResult
  func activateAgentConsole(
    agent: String? = nil,
    backend: String? = nil,
    acpCommand: String? = nil
  ) async -> MatrixBridgeService.AgentConsole? {
    let nom = agent ?? agentName
    var config = AgentConsoleConfig(agent: nom)
    config.owners = [await matrix.currentUserID]
    config.trigger = "@\(nom)"
    config.defaultMode = agentDefaultMode
    config.toolPreset = AgentConsoleConfig.ToolPreset.executer.rawValue
    // Le moteur est écrit dès la création : sans lui, un agent `hermes` naîtrait
    // avec le backend `claude` de l'amorce et répondrait avec le mauvais moteur.
    config.backend = backend
    config.acpCommand = acpCommand
    do {
      _ = try await matrix.ensureAgentConsole(agent: nom, config: config)
      return await loadAgentConsole(agent: nom)
    } catch {
      Self.relayLog.error("console impossible à créer : \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Ce Mac peut-il créer des agents ? Il faut être administrateur du Relais —
  /// on le vérifie avant de proposer, pas après avoir échoué.
  func canProvisionAgents() async -> Bool {
    await matrix.canProvisionAgents()
  }

  /// « Activer sur ce Mac » : le compte du bot sur le Relais, l'amorce sur le
  /// disque, le service dans macOS, et la console ouverte. Rend l'état du
  /// service — dont « à autoriser », qu'il faut montrer et pas espérer.
  func activateAgentOnThisMac(
    agent: String? = nil,
    backend: String? = nil,
    acpCommand: String? = nil
  ) async -> Result<AgentLocalHost.State, Error> {
    let nom = agent ?? agentName
    do {
      let bootstrap = try await matrix.provisionAgent(named: nom)
      let state = try AgentLocalHost.install(bootstrap: bootstrap, agent: nom)
      await activateAgentConsole(agent: nom, backend: backend, acpCommand: acpCommand)
      await inviteAgentToSelfNote(agent: nom)
      return .success(state)
    } catch {
      Self.relayLog.error("activation locale impossible : \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  /// Invite cc dans la note à soi.
  ///
  /// C'est le trou entre « actif » et « utilisable » : sans ça, on active un
  /// agent et on n'a nulle part où lui parler. La note à soi est l'endroit
  /// naturel — un tête-à-tête avec soi-même, où l'agent répond à voix haute
  /// puisqu'il n'y a personne à ménager.
  ///
  /// L'agent ne rejoint que sur invitation d'un propriétaire : c'est
  /// précisément celle-ci.
  func inviteAgentToSelfNote(agent: String? = nil) async {
    do {
      let roomID = try await matrix.ensureSelfNote()
      try await matrix.inviteAgentToRoom(roomID, agent: agent ?? agentName)
    } catch {
      Self.relayLog.error("cc non invité dans la note à soi : \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Le jeton d'amorce d'un hôte distant : le compte est créé sur le Relais,
  /// et la commande qui va avec porte l'amorce. Elle périme en dix minutes.
  ///
  /// Rend l'erreur telle quelle : l'écran disait « le Relais n'a pas voulu »
  /// quand c'était notre propre garde qui refusait, et on cherchait au mauvais
  /// endroit.
  func remoteAgentToken(
    agent: String? = nil,
    backend: String? = nil,
    acpCommand: String? = nil
  ) async -> Result<AgentBootstrapToken, Error> {
    let nom = agent ?? agentName
    do {
      let bootstrap = try await matrix.provisionAgent(named: nom)
      // La console est ouverte au passage : l'agent distant y trouvera sa
      // configuration dès qu'il se connectera.
      await activateAgentConsole(agent: nom, backend: backend, acpCommand: acpCommand)
      return .success(AgentBootstrapToken(bootstrap: bootstrap))
    } catch {
      Self.relayLog.error("jeton d'amorce impossible : \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  func deactivateAgentOnThisMac(agent: String? = nil) {
    try? AgentLocalHost.uninstall(agent: agent ?? agentName)
  }

  // MARK: - La voix de cc dans le fil ouvert

  /// La voix de cc dans le fil ouvert, ou `nil` s'il n'y est pas : le tiroir
  /// « + » n'affiche alors rien de plus qu'« Inviter cc ».
  func agentVoiceInSelectedConversation() async -> AgentSettings.Mode? {
    guard let conversation = selectedConversation, conversation.network.livesOnRelay,
          await matrix.hasAgent(conversationID: conversation.id),
          let roomID = await matrix.roomID(ofConversation: conversation.id)
    else { return nil }
    guard let console = await loadAgentConsole(), let config = console.config else {
      // Pas de console écrite : l'agent tourne sur son config.json, dont le
      // défaut est le brouillon. On dit ce qu'on sait, pas ce qu'on espère.
      return .draft
    }
    return config.voice(in: roomID)
  }

  /// Pose la voix de cc dans le fil ouvert, et allume ou éteint le relais du
  /// pont dans le même geste : à voix haute sans relais, le pont refuse le
  /// message et cc parle dans le vide. Rend la voix effective, ou `nil` si
  /// rien n'est parti — l'écran ne montre jamais un réglage qui n'a pas quitté
  /// l'app.
  func setAgentVoice(_ mode: AgentSettings.Mode) async -> AgentSettings.Mode? {
    guard let conversation = selectedConversation,
          let roomID = await matrix.roomID(ofConversation: conversation.id)
    else { return nil }
    // On part de ce que le Relais porte, jamais d'une config de départ : c'est
    // la config entière qui s'écrit, et ce qu'on n'a pas relu, on l'efface.
    var console = await loadAgentConsole()
    if console == nil { console = await activateAgentConsole() }
    guard let console, let config = console.config else {
      lastErrorMessage = "la console de cc n'est pas joignable — le réglage n'est pas parti"
      return nil
    }
    guard await writeAgentConsoleConfig(config.settingVoice(mode, in: roomID), in: console.roomID) else {
      lastErrorMessage = "le réglage n'est pas parti — il est resté sur ce Mac"
      return nil
    }
    do {
      let portail = try await matrix.setPortalRelay(conversationID: conversation.id, enabled: mode == .direct)
      if portail {
        Self.relayLog.info("relais du pont \(mode == .direct ? "allumé" : "éteint", privacy: .public) dans \(roomID, privacy: .public)")
      }
    } catch {
      lastErrorMessage = "cc répondra \(mode == .direct ? "à voix haute" : "en brouillon"), mais le pont n'a pas pris la commande de relais : \(error.localizedDescription)"
    }
    return mode
  }

  /// Écrit une configuration corrigée dans la console. Le retour dit si c'est
  /// parti : l'écran ne prétend pas avoir réglé ce qui n'a pas quitté l'app.
  @discardableResult
  func writeAgentConsoleConfig(_ config: AgentConsoleConfig, in roomID: String) async -> Bool {
    do {
      try await matrix.writeAgentConfig(config, in: roomID)
      return true
    } catch {
      Self.relayLog.error("réglage non écrit : \(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}
