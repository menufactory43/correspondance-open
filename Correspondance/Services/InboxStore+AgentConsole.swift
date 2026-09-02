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
    acpCommand: String? = nil,
    acpArguments: [String]? = nil
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
    config.acpArguments = acpArguments
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
    acpCommand: String? = nil,
    acpArguments: [String]? = nil
  ) async -> Result<AgentLocalHost.State, Error> {
    let nom = agent ?? agentName
    do {
      let bootstrap = try await matrix.provisionAgent(named: nom)
      let state = try AgentLocalHost.install(bootstrap: bootstrap, agent: nom)
      await activateAgentConsole(agent: nom, backend: backend, acpCommand: acpCommand, acpArguments: acpArguments)
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
    acpCommand: String? = nil,
    acpArguments: [String]? = nil
  ) async -> Result<AgentBootstrapToken, Error> {
    let nom = agent ?? agentName
    do {
      let bootstrap = try await matrix.provisionAgent(named: nom)
      // La console est ouverte au passage : l'agent distant y trouvera sa
      // configuration dès qu'il se connectera. Et l'invitation dans la note
      // à soi part maintenant : l'agent l'accepte à sa première synchro. Sans
      // elle, l'installeur finissait sur « @claude ping dans ta note à soi »
      // et le ping tombait dans une room où l'agent n'était pas — vu en vrai.
      await activateAgentConsole(agent: nom, backend: backend, acpCommand: acpCommand, acpArguments: acpArguments)
      await inviteAgentToSelfNote(agent: nom)
      return .success(AgentBootstrapToken(bootstrap: bootstrap))
    } catch {
      Self.relayLog.error("jeton d'amorce impossible : \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  func deactivateAgentOnThisMac(agent: String? = nil) {
    try? AgentLocalHost.uninstall(agent: agent ?? agentName)
  }

  // MARK: - Qui est là, et de quelle voix

  /// L'annuaire, relu depuis le Relais. À appeler quand on change de
  /// conversation ou qu'on vient d'activer un agent : la liste décide entre un
  /// bouton « Inviter cc » et un menu, et un menu qui invente des noms serait
  /// pire qu'un bouton unique.
  func refreshAgentDirectory() async {
    let noms = await listAgentConsoles().map(\.agent)
    // Repli sur le nom par défaut tant qu'aucune console n'existe : c'est le
    // premier agent qu'on active, et il faut bien pouvoir l'inviter.
    agentDirectory = noms.isEmpty ? [agentName] : noms
    // C'est ce qui fait qu'un `@claude` ou un `@grok` a sa propre tête dans
    // le fil au lieu de celle de la correspondante.
    MatrixIdentity.registerAgents(noms)
  }

  /// Les agents connus qui **ne sont pas** dans le fil ouvert. Vide quand il
  /// n'y a rien à inviter : le tiroir « + » n'affiche alors pas d'étincelle.
  func invitableAgents() async -> [String] {
    guard let conversation = selectedConversation, conversation.network.livesOnRelay else { return [] }
    let connus = agentDirectory.isEmpty ? [agentName] : agentDirectory
    var absents: [String] = []
    for nom in connus where await !matrix.hasAgent(conversationID: conversation.id, agent: nom) {
      absents.append(nom)
    }
    return absents
  }

  /// La voix de chaque agent **présent** dans le fil ouvert. Un agent sans
  /// console écrite tourne sur son `config.json`, dont le défaut est le
  /// brouillon : on dit ce qu'on sait, pas ce qu'on espère.
  func agentVoicesInSelectedConversation() async -> [AgentVoice] {
    guard let conversation = selectedConversation, conversation.network.livesOnRelay,
          let roomID = await matrix.roomID(ofConversation: conversation.id)
    else { return [] }
    let configs = (try? await matrix.agentConfigs()) ?? []
    let connus = agentDirectory.isEmpty ? [agentName] : agentDirectory
    var voix: [AgentVoice] = []
    for nom in connus where await matrix.hasAgent(conversationID: conversation.id, agent: nom) {
      let config = configs.first { $0.agent == nom }
      voix.append(AgentVoice(agent: nom, mode: config?.voice(in: roomID) ?? .draft))
    }
    return voix.sorted { $0.agent < $1.agent }
  }

  /// Fait de la conversation ouverte un **atelier** quand plusieurs agents y
  /// sont : chaque agent présent apprend les autres (`peers` dans sa console).
  ///
  /// C'est ce qui arme les deux règles du salon d'agents
  /// (`docs/PLAN-relais-agents.md`, § « Salons d'agents ») : la **mention est
  /// obligatoire**, et **un agent ne déclenche pas un agent**. Sans `peers`,
  /// deux agents dans une même room se répondraient l'un l'autre jusqu'au
  /// plafond horaire — la boucle est le seul vrai danger de l'atelier.
  ///
  /// On n'**ajoute** que : `peers` vaut pour tout l'agent, pas pour ce salon,
  /// et l'effacer en quittant une conversation désarmerait les autres.
  func linkAgentPeersInSelectedConversation() async {
    guard let conversation = selectedConversation else { return }
    let connus = agentDirectory.isEmpty ? [agentName] : agentDirectory
    var presents: [String] = []
    for nom in connus where await matrix.hasAgent(conversationID: conversation.id, agent: nom) {
      presents.append(nom)
    }
    guard presents.count > 1 else { return }
    let moi = await matrix.currentUserID
    for nom in presents {
      let autres = presents.filter { $0 != nom }
        .map { MatrixIdentity.agentUserID(named: $0, sameServerAs: moi) }
      guard let console = await loadAgentConsole(agent: nom), var config = console.config else { continue }
      let deja = Set(config.peers ?? [])
      guard !Set(autres).isSubset(of: deja) else { continue }
      config.peers = deja.union(autres).sorted()
      await writeAgentConsoleConfig(config, in: console.roomID)
      Self.relayLog.info("atelier : \(nom, privacy: .public) connaît maintenant ses pairs")
    }
  }

  /// Pose la voix d'**un** agent dans le fil ouvert, dans *sa* console, puis
  /// réaccorde le relais du pont.
  ///
  /// Le relais, lui, est commun à la room : c'est une commande donnée au pont,
  /// pas un réglage d'agent. Il s'allume dès qu'un agent présent parle à voix
  /// haute et s'éteint quand plus aucun ne le fait — l'éteindre parce que
  /// *celui-ci* passe en brouillon ferait parler l'autre dans le vide (« You're
  /// not logged in (relay not set) », vu en vrai).
  ///
  /// Rend la voix effective, ou `nil` si rien n'est parti : l'écran ne montre
  /// jamais un réglage qui n'a pas quitté l'app.
  func setAgentVoice(_ mode: AgentSettings.Mode, agent: String) async -> AgentSettings.Mode? {
    guard let conversation = selectedConversation,
          let roomID = await matrix.roomID(ofConversation: conversation.id)
    else { return nil }
    // On part de ce que le Relais porte, jamais d'une config de départ : c'est
    // la config entière qui s'écrit, et ce qu'on n'a pas relu, on l'efface.
    var console = await loadAgentConsole(agent: agent)
    if console == nil { console = await activateAgentConsole(agent: agent) }
    guard let console, let config = console.config else {
      lastErrorMessage = "la console de \(agent) n'est pas joignable — le réglage n'est pas parti"
      return nil
    }
    guard await writeAgentConsoleConfig(config.settingVoice(mode, in: roomID), in: console.roomID) else {
      lastErrorMessage = "le réglage n'est pas parti — il est resté sur ce Mac"
      return nil
    }

    let voixHaute = await voixHauteDansLeFil(roomID: roomID, apres: (agent, mode))
    do {
      let portail = try await matrix.setPortalRelay(conversationID: conversation.id, enabled: voixHaute)
      if portail {
        Self.relayLog.info(
          "relais du pont \(voixHaute ? "allumé" : "éteint", privacy: .public) dans \(roomID, privacy: .public)"
        )
      }
    } catch {
      lastErrorMessage = "\(agent) répondra \(mode == .direct ? "à voix haute" : "en brouillon"), "
        + "mais le pont n'a pas pris la commande de relais : \(error.localizedDescription)"
    }
    return mode
  }

  /// Au moins un agent présent parle-t-il à voix haute ici, une fois ce
  /// changement pris en compte ? La voix qu'on vient d'écrire prime sur ce
  /// qu'on relit : le `/sync` n'a pas forcément rapporté l'écriture.
  private func voixHauteDansLeFil(roomID: String, apres: (agent: String, mode: AgentSettings.Mode)) async -> Bool {
    if apres.mode == .direct { return true }
    let voix = await agentVoicesInSelectedConversation()
    return voix.contains { $0.agent != apres.agent && $0.mode == .direct }
  }

  /// Ouvre le tête-à-tête avec un agent — le fil existant, ou un salon neuf
  /// où il est invité — et le sélectionne. La voix y est posée « à voix
  /// haute » : dans un fil où il n'y a que lui et moi, un brouillon à valider
  /// n'aurait personne à protéger.
  func openAgentConversation(agent: String) async {
    do {
      let id = try await matrix.openAgentConversation(agent: agent)
      await reloadFromRelay()
      mode = .inbox
      await select(id)
      if await agentVoicesInSelectedConversation().first(where: { $0.agent == agent })?.mode != .direct {
        _ = await setAgentVoice(.direct, agent: agent)
      }
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  /// Demande à un agent de rescanner sa machine. Le retour dit si l'ordre est
  /// parti ; le résultat, lui, arrive dans son prochain status.
  func requestAgentRescan(_ console: MatrixBridgeService.AgentConsole) async -> Bool {
    do {
      try await matrix.requestAgentRescan(agent: console.agent, in: console.roomID)
      return true
    } catch {
      Self.relayLog.error("rescan non demandé : \(error.localizedDescription, privacy: .public)")
      return false
    }
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

/// La voix d'un agent dans une conversation — ce que le tiroir « + » affiche
/// quand plusieurs agents sont dans le fil. Un bouton par agent, chacun réglant
/// **sa** console : deux agents dans un salon n'ont aucune raison de parler de
/// la même façon.
struct AgentVoice: Identifiable, Equatable, Sendable {
  let agent: String
  let mode: AgentSettings.Mode

  var id: String { agent }
}
