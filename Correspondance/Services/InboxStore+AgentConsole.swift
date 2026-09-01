import CorrespondanceCore
import Foundation

/// Ce que l'app fait de la room console d'un agent : l'ouvrir, y écrire les
/// réglages, y lire le status et le journal.
///
/// Rien ici ne parle à l'agent directement — on écrit sur le Relais, il relit à
/// son prochain `/sync`. C'est tout le sujet de la phase 1 : un réglage change
/// sans SSH et sans redémarrage.
extension InboxStore {

  /// Le nom de l'agent qu'on règle. Un seul pour l'instant ; la console est
  /// déjà par agent, l'écran suivra quand il y en aura deux.
  var agentName: String { MatrixIdentity.agentName }

  /// Ce que la console raconte, ou `nil` si elle n'existe pas encore.
  func loadAgentConsole() async -> MatrixBridgeService.AgentConsole? {
    do {
      return try await matrix.readAgentConsole(agent: agentName)
    } catch {
      Self.relayLog.error("console de l'agent illisible : \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Crée la console si elle manque et y écrit la configuration de départ —
  /// le geste de la première activation. L'agent est invité au passage ; il
  /// rejoint parce qu'un propriétaire l'a invité, et découvre sa config seul.
  @discardableResult
  func activateAgentConsole() async -> MatrixBridgeService.AgentConsole? {
    var config = AgentConsoleConfig(agent: agentName)
    config.owners = [await matrix.currentUserID]
    config.trigger = "@\(agentName)"
    config.defaultMode = agentDefaultMode
    config.toolPreset = AgentConsoleConfig.ToolPreset.executer.rawValue
    do {
      _ = try await matrix.ensureAgentConsole(agent: agentName, config: config)
      return await loadAgentConsole()
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
  func activateAgentOnThisMac() async -> Result<AgentLocalHost.State, Error> {
    do {
      let bootstrap = try await matrix.provisionAgent(named: agentName)
      let state = try AgentLocalHost.install(bootstrap: bootstrap, agent: agentName)
      await activateAgentConsole()
      return .success(state)
    } catch {
      Self.relayLog.error("activation locale impossible : \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  func deactivateAgentOnThisMac() {
    try? AgentLocalHost.uninstall(agent: agentName)
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
