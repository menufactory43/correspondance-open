import AppKit
import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// **Réglages › Agents** : tous les agents du Relais, et les moteurs de ce Mac.
///
/// Trois règles tiennent cet écran, et elles viennent toutes d'incidents réels
/// racontés dans `docs/AGENT.md` :
///
/// 1. **L'annuaire, c'est le Relais.** « Quels agents existent » se lit dans les
///    rooms console (`listAgentConsoles`), jamais dans un drapeau posé par
///    l'app : l'agent du NUC n'a jamais été activé depuis ce Mac et il existe.
/// 2. **Chaque état vient d'une preuve** — un status daté, un processus que
///    l'app surveille, un fichier d'amorce sur le disque, un binaire trouvé.
///    L'écran a déjà affirmé « actif » sur la foi d'un drapeau alors que rien
///    n'existait ; on ne recommence pas.
/// 3. **Les moteurs vivent là où l'agent tourne.** Le catalogue local ne parle
///    que de ce Mac ; ceux d'un hôte distant se lisent dans le status de
///    l'agent qui y tourne.
struct SettingsAgentsPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  /// L'annuaire, tel que le Relais le porte.
  @State private var consoles: [MatrixBridgeService.AgentConsole] = []
  /// Le catalogue local, tel que le disque le porte.
  @State private var moteurs: [EngineCatalog.Finding] = []
  @State private var isLoading = false
  /// L'agent (ou le moteur) sur lequel un geste est en cours.
  @State private var enCours: String?
  @State private var erreur: String?
  @State private var peutProvisionner = false
  /// Les noms proposés pour les activations, modifiables : le nom du moteur
  /// est une proposition, pas une contrainte.
  @State private var nomsProposes: [String: String] = [:]
  /// Les commandes d'installation préparées, par clé (« agent » ou
  /// « moteur@machine ») — vivantes dix minutes.
  @State private var commandes: [String: (texte: String, expire: Date)] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if let erreur {
        SettingsCard(title: "Ce qui n'est pas passé") {
          SettingsRow(label: erreur, systemImage: "exclamationmark.triangle") {
            Button("Fermer") { self.erreur = nil }
          }
        }
      }

      if consoles.isEmpty && !isLoading {
        SettingsCard(
          title: "Agents",
          footnote: "Un agent est un compte Matrix, une console et un moteur. "
            + "L'annuaire se lit sur le Relais : tant qu'aucune console n'existe, il est vide."
        ) {
          SettingsRow(
            label: "Aucun agent",
            detail: "Active un moteur de ce Mac ci-dessous, ou prépare une commande pour une autre machine.",
            systemImage: "person.crop.circle.badge.questionmark"
          ) {
            if isLoading { ProgressView().controlSize(.small) } else {
              Button("Rafraîchir") { Task { await recharger() } }
            }
          }
        }
      }

      ForEach(consoles) { console in
        agentCard(console)
      }

      moteursCard
      hotesDistantsCard

      Text("Un réglage part sur le Relais ; l'agent le relit à sa prochaine synchronisation.")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(themes.theme.inkTertiary)
    }
    .task { await recharger() }
    // On installe un moteur dans un terminal, on revient : la carte doit le
    // voir sans qu'on ferme et rouvre les réglages.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await rescannerLesMoteurs() }
    }
  }

  // MARK: - Un agent

  /// Ce qu'on affiche d'un agent, et **d'où ça vient** :
  /// - l'hôte et les moteurs prêts : de son status, qu'il a lui-même publié ;
  /// - « local » : de son amorce, constatée sur le disque de ce Mac ;
  /// - vivant ou muet : de la date de ce status.
  @ViewBuilder
  private func agentCard(_ console: MatrixBridgeService.AgentConsole) -> some View {
    let agent = console.agent
    let local = AgentLocalHost.hasBootstrap(agent: agent)
    let etatLocal = AgentLocalHost.state(agent: agent, dernierStatus: console.status?.publishedAt)

    SettingsCard(title: agent, footnote: footnoteFor(console, local: local)) {
      SettingsRow(label: "Où il tourne", detail: ouEtQuoi(console), systemImage: "cpu") {
        if enCours == agent {
          ProgressView().controlSize(.small)
        } else if local {
          boutonLocal(agent: agent, etat: etatLocal)
        } else {
          Button("Rafraîchir") { Task { await recharger() } }
        }
      }

      if let status = console.status, !status.enginesReady.isEmpty {
        SettingsRow(
          label: "Moteurs prêts là-bas",
          detail: status.enginesReady.joined(separator: ", ")
            + " — d'après ce que l'agent a scanné sur sa machine.",
          systemImage: "wrench.and.screwdriver"
        ) { EmptyView() }
      }

      if local, let journal = AgentLocalHost.logURL(agent: agent) {
        SettingsRow(label: "Journal", detail: journal.path(), systemImage: "waveform.path") {
          Button("Ouvrir") { NSWorkspace.shared.open(journal) }
        }
      }

      if let config = console.config {
        reglages(console: console, config: config)
      }

      SettingsRow(
        label: "Sur une autre machine",
        detail: commandeDetail(cle: agent),
        systemImage: "server.rack"
      ) {
        if let commande = commandes[agent]?.texte {
          Button("Copier") { copier(commande) }
        } else {
          Button("Préparer la commande") {
            Task { await preparerCommande(agent: agent, cle: agent, backend: nil, acpCommand: nil) }
          }
          .disabled(!peutProvisionner || enCours != nil)
        }
      }

      if !console.journal.isEmpty {
        ForEach(console.journal.prefix(3)) { tour in
          SettingsRow(
            label: tour.prompt.isEmpty ? "(sans texte)" : tour.prompt,
            detail: tour.summaryFR,
            systemImage: "clock.arrow.circlepath"
          ) {
            Text(tour.at.formatted(date: .omitted, time: .shortened))
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(themes.theme.inkTertiary)
          }
        }
      }
    }
  }

  /// L'état, dit une seule fois, avec sa provenance. Un écran qui affirme deux
  /// choses contradictoires est pire qu'un écran qui en affirme une fausse.
  private func ouEtQuoi(_ console: MatrixBridgeService.AgentConsole) -> String {
    guard let status = console.status else {
      return AgentLocalHost.hasBootstrap(agent: console.agent)
        ? "amorcé sur ce Mac ; il n'a encore rien publié dans sa console"
        : "console ouverte ; il n'a encore rien publié — on ne sait pas où il tourne"
    }
    let ou = status.host.map { $0 == EngineCatalog.nomDeCeMac ? "sur ce Mac" : "sur \($0)" }
      ?? "quelque part — son status ne dit pas où"
    let moteur = status.backend.map { " · moteur \($0)" } ?? ""
    let age = status.publishedAt
      .formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
    return status.isFresh()
      ? "\(ou)\(moteur) — vu \(age)"
      : "\(ou)\(moteur) — muet depuis \(age) : plus rien depuis plus d'une heure"
  }

  private func footnoteFor(_ console: MatrixBridgeService.AgentConsole, local: Bool) -> String {
    local
      ? "Son amorce est sur ce Mac : il tourne tant que Correspondance est ouverte. "
        + "Pour qu'il réponde jour et nuit, installe-le sur une autre machine."
      : "Son amorce n'est pas sur ce Mac. Ce que dit cette carte vient de ce que l'agent publie "
        + "lui-même dans sa console."
  }

  /// Chaque état a une sortie : un écran qui affiche un fait sans offrir
  /// d'action est un cul-de-sac.
  @ViewBuilder
  private func boutonLocal(agent: String, etat: AgentLocalHost.State) -> some View {
    switch etat {
    case .actif, .silencieux:
      Button("Arrêter") {
        store.deactivateAgentOnThisMac(agent: agent)
        Task { await recharger() }
      }
    case .absent:
      Button("Démarrer") {
        Task {
          enCours = agent
          defer { enCours = nil }
          AgentLocalHost.resume(agent: agent, force: true)
          await recharger()
        }
      }
    case .incomplet, .abandonne:
      Button("Réparer") {
        Task {
          AgentLocalHost.reset(agent: agent)
          await activer(agent: agent, backend: nil, acpCommand: nil)
        }
      }
      .disabled(!peutProvisionner)
    case .introuvable:
      Button("Pourquoi ?") { erreur = AgentLocalHost.aideIntrouvable }
    }
  }

  // MARK: - Les réglages d'un agent

  @ViewBuilder
  private func reglages(
    console: MatrixBridgeService.AgentConsole, config: AgentConsoleConfig
  ) -> some View {
    SettingsRow(
      label: "Outils",
      detail: (AgentConsoleConfig.ToolPreset(rawValue: config.toolPreset ?? "")?.subtitleFR)
        ?? "réglés à la main sur sa machine",
      systemImage: "wrench.and.screwdriver"
    ) {
      Picker("", selection: Binding(
        get: { AgentConsoleConfig.ToolPreset(rawValue: config.toolPreset ?? "") ?? .executer },
        set: { palier in Task { await ecrire(console: console) { $0.toolPreset = palier.rawValue } } }
      )) {
        ForEach(AgentConsoleConfig.ToolPreset.allCases) { palier in Text(palier.labelFR).tag(palier) }
      }
      .pickerStyle(.menu)
      .frame(width: 220)
    }

    SettingsRow(
      label: "Voix par défaut",
      detail: (config.defaultMode ?? .draft).subtitleFR
        + " — une conversation peut dire autrement, sous son « + ».",
      systemImage: "person.2.wave.2"
    ) {
      Picker("", selection: Binding(
        get: { config.defaultMode ?? .draft },
        set: { mode in Task { await ecrire(console: console) { $0.defaultMode = mode } } }
      )) {
        Text("Brouillon à valider").tag(AgentSettings.Mode.draft)
        Text("À voix haute").tag(AgentSettings.Mode.direct)
      }
      .pickerStyle(.menu)
      .frame(width: 190)
    }

    SettingsRow(
      label: "Demandes par heure",
      detail: "au-delà, l'agent répond qu'il faut attendre",
      systemImage: "gauge.with.needle"
    ) {
      Picker("", selection: Binding(
        get: { config.hourlyCap ?? 30 },
        set: { plafond in Task { await ecrire(console: console) { $0.hourlyCap = plafond } } }
      )) {
        ForEach([10, 30, 60, 120], id: \.self) { Text("\($0)").tag($0) }
      }
      .pickerStyle(.menu)
      .frame(width: 90)
    }
  }

  // MARK: - Ajouter un agent : les moteurs de ce Mac

  private var moteursCard: some View {
    SettingsCard(
      title: "Ajouter un agent sur ce Mac",
      footnote: "Un moteur prêt donne un agent en un clic : compte sur le Relais, amorce sur le "
        + "disque, console avec son moteur, processus enfant, et invitation dans ta note à soi. "
        + "Un moteur absent affiche ce qu'il faut taper — pas un bouton qui mentirait."
    ) {
      SettingsRow(
        label: "Ce que ce Mac sait lancer",
        detail: "Scanné à l'ouverture de cet écran et à chaque retour dans l'app. "
          + "Tu viens d'installer un moteur dans un terminal ? Rafraîchis.",
        systemImage: "magnifyingglass"
      ) {
        if isLoading { ProgressView().controlSize(.small) } else {
          Button("Rafraîchir") { Task { await rescannerLesMoteurs() } }
        }
      }

      ForEach(moteurs) { trouve in
        SettingsRow(
          label: trouve.entry.labelFR,
          detail: detailMoteur(trouve),
          systemImage: trouve.state.estPret ? "checkmark.seal" : "questionmark.circle"
        ) {
          if trouve.state.estPret {
            HStack(spacing: Spacing.xs) {
              TextField(
                "nom",
                text: Binding(
                  get: { nomsProposes[trouve.entry.id] ?? trouve.entry.nomAgentPropose },
                  set: { nomsProposes[trouve.entry.id] = $0 }
                )
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)

              if enCours == trouve.entry.id {
                ProgressView().controlSize(.small)
              } else {
                Button("Activer") { Task { await activerMoteur(trouve) } }
                  .disabled(!peutProvisionner || nomDejaPris(trouve) || enCours != nil)
              }
            }
          } else {
            Button("Copier la commande") { copier(trouve.entry.indiceInstallation) }
          }
        }
      }
    }
  }

  private func detailMoteur(_ trouve: EngineCatalog.Finding) -> String {
    var texte = trouve.state.labelFR
    if let path = trouve.path { texte += " · \(path)" }
    if !trouve.state.estPret { texte += "\n\(trouve.entry.indiceInstallation)" }
    if trouve.state.estPret, nomDejaPris(trouve) {
      texte += "\nUn agent porte déjà ce nom : donne-lui-en un autre."
    }
    if !peutProvisionner, trouve.state.estPret {
      texte += "\nIl faut être administrateur du Relais pour créer un compte d'agent."
    }
    return texte
  }

  private func nomDejaPris(_ trouve: EngineCatalog.Finding) -> Bool {
    let nom = nomsProposes[trouve.entry.id] ?? trouve.entry.nomAgentPropose
    return consoles.contains { $0.agent == nom }
  }

  // MARK: - Ajouter un agent sur une machine connue

  /// Les hôtes distants dont on sait quelque chose : un agent y tourne et a
  /// publié ce qu'il y a trouvé. On ne propose que des moteurs **constatés
  /// là-bas** — proposer un moteur qu'on n'a vu nulle part serait une promesse.
  private var hotesDistants: [(hote: String, moteurs: [String])] {
    var parHote: [String: Set<String>] = [:]
    for console in consoles {
      guard let status = console.status, let hote = status.host,
            hote != EngineCatalog.nomDeCeMac
      else { continue }
      parHote[hote, default: []].formUnion(status.enginesReady)
    }
    // Un moteur déjà porté par un agent de cette machine n'est plus à ajouter.
    for console in consoles {
      guard let status = console.status, let hote = status.host, let backend = status.backend
      else { continue }
      parHote[hote]?.remove(backend)
    }
    return parHote
      .map { (hote: $0.key, moteurs: $0.value.sorted()) }
      .filter { !$0.moteurs.isEmpty }
      .sorted { $0.hote < $1.hote }
  }

  @ViewBuilder
  private var hotesDistantsCard: some View {
    if !hotesDistants.isEmpty {
      SettingsCard(
        title: "Ajouter un agent ailleurs",
        footnote: "Ces moteurs sont ceux qu'un agent a scannés sur sa machine — c'est la seule "
          + "chose qu'on sache d'un hôte distant. La commande contient un mot de passe : elle se "
          + "colle dans un terminal, jamais dans une conversation, et périme en dix minutes."
      ) {
        ForEach(hotesDistants, id: \.hote) { hote in
          ForEach(hote.moteurs, id: \.self) { moteur in
            let cle = "\(moteur)@\(hote.hote)"
            SettingsRow(
              label: "\(moteur) sur \(hote.hote)",
              detail: commandeDetail(cle: cle),
              systemImage: "server.rack"
            ) {
              if let commande = commandes[cle]?.texte {
                Button("Copier") { copier(commande) }
              } else {
                Button("Préparer la commande") {
                  Task {
                    let entree = EngineCatalog.entries.first { $0.id == moteur || $0.acpCommand == moteur }
                    await preparerCommande(
                      agent: nomLibre(base: entree?.nomAgentPropose ?? moteur),
                      cle: cle,
                      backend: entree?.backend.rawValue,
                      acpCommand: entree?.acpCommand,
                      acpArguments: entree?.acpArguments
                    )
                  }
                }
                .disabled(!peutProvisionner || enCours != nil)
              }
            }
          }
        }
      }
    }
  }

  private func commandeDetail(cle: String) -> String {
    guard let commande = commandes[cle] else {
      return peutProvisionner
        ? "une commande à coller en SSH, et l'agent répond même Mac fermé"
        : "il faut être administrateur du Relais pour créer un agent"
    }
    return commande.expire <= Date() ? "la commande a expiré — reprends-en une" : commande.texte
  }

  /// Un nom qui n'est pris par aucune console. Deux agents du même nom, ce
  /// serait le même compte Matrix et deux réponses au même message.
  private func nomLibre(base: String) -> String {
    guard consoles.contains(where: { $0.agent == base }) else { return base }
    for suffixe in 2...9 where !consoles.contains(where: { $0.agent == "\(base)\(suffixe)" }) {
      return "\(base)\(suffixe)"
    }
    return base
  }

  // MARK: - Les gestes

  private func recharger() async {
    isLoading = true
    defer { isLoading = false }
    consoles = await store.listAgentConsoles()
    peutProvisionner = await store.canProvisionAgents()
    // Le scan touche le disque et lance des `--version` : hors de l'acteur
    // principal, sinon l'écran se fige le temps qu'un moteur réponde.
    moteurs = await Task.detached { EngineCatalog.scan() }.value
  }

  /// Le scan seul, sans repasser par le Relais : c'est le disque de ce Mac
  /// qui a changé, pas l'annuaire.
  private func rescannerLesMoteurs() async {
    moteurs = await Task.detached { EngineCatalog.scan() }.value
  }

  private func activerMoteur(_ trouve: EngineCatalog.Finding) async {
    let nom = (nomsProposes[trouve.entry.id] ?? trouve.entry.nomAgentPropose)
      .trimmingCharacters(in: .whitespaces)
    guard !nom.isEmpty else {
      erreur = "un agent a besoin d'un nom — c'est son compte sur le Relais"
      return
    }
    enCours = trouve.entry.id
    defer { enCours = nil }
    await activer(
      agent: nom, backend: trouve.entry.backend.rawValue,
      acpCommand: trouve.entry.acpCommand, acpArguments: trouve.entry.acpArguments
    )
  }

  private func activer(agent: String, backend: String?, acpCommand: String?, acpArguments: [String]? = nil) async {
    erreur = nil
    switch await store.activateAgentOnThisMac(agent: agent, backend: backend, acpCommand: acpCommand, acpArguments: acpArguments) {
    case .success:
      // On n'affiche pas l'état rendu par l'installation : il ne connaît pas
      // le status de l'agent, qui n'a pas encore eu le temps de parler. On
      // attend qu'il parle — six essais, dix secondes ; au-delà c'est un vrai
      // problème et la carte le dira.
      for _ in 0..<6 {
        await recharger()
        if consoles.first(where: { $0.agent == agent })?.status?.isFresh() == true { break }
        try? await Task.sleep(for: .seconds(2))
      }
    case .failure(let raison):
      erreur = raison.localizedDescription
      await recharger()
    }
  }

  private func preparerCommande(
    agent: String, cle: String, backend: String?, acpCommand: String?, acpArguments: [String]? = nil
  ) async {
    enCours = cle
    defer { enCours = nil }
    erreur = nil
    switch await store.remoteAgentToken(agent: agent, backend: backend, acpCommand: acpCommand, acpArguments: acpArguments) {
    case .success(let jeton):
      commandes[cle] = (texte: jeton.installCommand(), expire: jeton.expiresAt)
      await recharger()
    case .failure(let raison):
      erreur = raison.localizedDescription
    }
  }

  private func ecrire(
    console: MatrixBridgeService.AgentConsole,
    _ mutation: (inout AgentConsoleConfig) -> Void
  ) async {
    guard var config = console.config else { return }
    mutation(&config)
    if await !store.writeAgentConsoleConfig(config, in: console.roomID) {
      erreur = "le réglage n'est pas parti — il est resté sur ce Mac"
    }
    await recharger()
  }

  private func copier(_ texte: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(texte, forType: .string)
  }
}
