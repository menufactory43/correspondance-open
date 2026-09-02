import AppKit
import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceUI
import SwiftUI

/// **Réglages › Agents** : tous les agents du Relais, puis « Ajouter un agent »
/// avec le choix de l'hôte — ce Mac, une machine où un agent tourne déjà, ou
/// une autre.
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
///    l'agent qui y tourne — nom, adresse, moteurs prêts, moteurs à connecter.
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
  /// Les commandes d'installation préparées, par clé (« agent »,
  /// « moteur@machine » ou « autre ») — vivantes dix minutes.
  @State private var commandes: [String: (texte: String, expire: Date)] = [:]
  /// Où ajouter le prochain agent.
  @State private var hoteChoisi: HoteChoix = .ceMac
  /// Pour « une autre machine » : le moteur et le nom du futur agent.
  @State private var moteurAutre: String = "claude"
  @State private var nomAutre: String = ""

  /// Un hôte où l'on peut ajouter un agent.
  enum HoteChoix: Hashable {
    case ceMac
    /// Une machine où un agent tourne déjà et a publié ce qu'il y a vu.
    case connu(String)
    /// Une machine dont on ne sait rien encore : la commande d'installation.
    case autre
  }

  /// Ce qu'on sait d'une machine distante — **uniquement** ce que les agents
  /// qui y tournent ont publié. Fusionné par nom d'hôte quand plusieurs y sont.
  struct HoteConnu: Identifiable {
    var nom: String
    var adresse: String?
    /// La console la plus fraîche de cette machine : c'est à elle qu'on
    /// demande de rescanner, et c'est sa date qu'on affiche.
    var console: MatrixBridgeService.AgentConsole
    var prets: [String]
    var aConnecter: [String]
    /// Les moteurs qu'un agent de cette machine porte déjà.
    var portes: Set<String>

    var id: String { nom }
    var disponibles: [String] { prets.filter { !portes.contains($0) } }
  }

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
          footnote: "Un agent est un compte sur le Relais, une console et un moteur. "
            + "L'annuaire se lit sur le Relais : tant qu'aucune console n'existe, il est vide."
        ) {
          SettingsRow(
            label: "Aucun agent",
            detail: "Ajoute-en un ci-dessous : sur ce Mac, ou sur une machine qui reste allumée.",
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

      ajouterCard

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
  /// - l'hôte, son adresse et les moteurs : de son status, qu'il a lui-même publié ;
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

      if let status = console.status {
        SettingsRow(
          label: "Moteurs sur sa machine",
          detail: moteursLaBas(status),
          systemImage: "wrench.and.screwdriver"
        ) {
          if enCours == "rescan:\(agent)" {
            ProgressView().controlSize(.small)
          } else {
            Button("Rescanner") { Task { await rescannerLaBas(console) } }
              .disabled(enCours != nil)
          }
        }
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
        label: "Déplacer sur une autre machine",
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
    let ou = status.host.map { hote in
      hote == EngineCatalog.nomDeCeMac ? "sur ce Mac" : "sur \(Self.nomEtAdresse(hote, status.address))"
    } ?? "quelque part — son status ne dit pas où"
    let moteur = status.backend.map { " · moteur \($0)" } ?? ""
    let age = status.publishedAt
      .formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
    return status.isFresh()
      ? "\(ou)\(moteur) — vu \(age)"
      : "\(ou)\(moteur) — muet depuis \(age) : plus rien depuis plus d'une heure"
  }

  /// « umbrel (100.64.0.12) » — l'adresse à côté du nom, parce qu'un nom seul
  /// ne dit pas où coller une commande SSH.
  static func nomEtAdresse(_ nom: String, _ adresse: String?) -> String {
    adresse.map { "\(nom) (\($0))" } ?? nom
  }

  private func moteursLaBas(_ status: MatrixBridgeService.AgentStatus) -> String {
    var parts: [String] = []
    parts.append("prêts : " + (status.enginesReady.isEmpty ? "aucun" : status.enginesReady.joined(separator: ", ")))
    if !status.enginesToConnect.isEmpty {
      parts.append("à connecter : " + status.enginesToConnect.joined(separator: ", "))
    }
    return parts.joined(separator: " · ") + " — d'après son scan, au démarrage ou au dernier « Rescanner »."
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

  // MARK: - Ajouter un agent

  /// Les machines distantes dont on sait quelque chose, fusionnées par nom.
  private var hotesConnus: [HoteConnu] {
    var parNom: [String: HoteConnu] = [:]
    for console in consoles {
      guard let status = console.status, let nom = status.host, nom != EngineCatalog.nomDeCeMac
      else { continue }
      if var hote = parNom[nom] {
        hote.prets = Array(Set(hote.prets).union(status.enginesReady)).sorted()
        hote.aConnecter = Array(Set(hote.aConnecter).union(status.enginesToConnect)).sorted()
        if hote.adresse == nil { hote.adresse = status.address }
        if status.publishedAt > (hote.console.status?.publishedAt ?? .distantPast) { hote.console = console }
        if let backend = status.backend { hote.portes.insert(backend) }
        parNom[nom] = hote
      } else {
        parNom[nom] = HoteConnu(
          nom: nom, adresse: status.address, console: console,
          prets: status.enginesReady, aConnecter: status.enginesToConnect,
          portes: Set(status.backend.map { [$0] } ?? [])
        )
      }
    }
    return parNom.values.sorted { $0.nom < $1.nom }
  }

  private var ajouterCard: some View {
    SettingsCard(title: "Ajouter un agent", footnote: footnoteAjout) {
      SettingsRow(label: "Où", detail: detailHote, systemImage: "location") {
        Picker("", selection: $hoteChoisi) {
          Text("Ce Mac").tag(HoteChoix.ceMac)
          ForEach(hotesConnus) { hote in
            Text(Self.nomEtAdresse(hote.nom, hote.adresse)).tag(HoteChoix.connu(hote.nom))
          }
          Text("Une autre machine").tag(HoteChoix.autre)
        }
        .pickerStyle(.menu)
        .frame(width: 220)
      }

      switch hoteChoisi {
      case .ceMac:
        ForEach(moteurs) { trouve in ligneMoteurLocal(trouve) }
      case .connu(let nom):
        if let hote = hotesConnus.first(where: { $0.nom == nom }) {
          lignesHoteConnu(hote)
        } else {
          SettingsRow(
            label: "Cette machine n'a plus publié",
            detail: "Aucun agent n'y a parlé récemment : choisis un autre hôte.",
            systemImage: "questionmark.circle"
          )
        }
      case .autre:
        lignesAutreMachine
      }
    }
  }

  private var footnoteAjout: String {
    switch hoteChoisi {
    case .ceMac:
      "Un moteur prêt donne un agent en un clic : compte sur le Relais, console avec son moteur, "
        + "processus enfant, et invitation dans ta note à soi. Il tourne tant que Correspondance est ouverte."
    case .connu:
      "Ce qu'on sait de cette machine vient des agents qui y tournent. La commande contient un mot de "
        + "passe : elle se colle dans un terminal là-bas, jamais dans une conversation, et périme en dix minutes."
    case .autre:
      "Une machine qui reste allumée : l'agent répond même Mac fermé. La commande installe l'agent avec "
        + "son moteur ; le moteur lui-même, et sa connexion, se font là-bas."
    }
  }

  private var detailHote: String {
    switch hoteChoisi {
    case .ceMac:
      return "Ce que ce Mac sait lancer, scanné à l'ouverture et à chaque retour dans l'app."
    case .connu(let nom):
      if let hote = hotesConnus.first(where: { $0.nom == nom }), let status = hote.console.status {
        let age = status.publishedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
        return "D'après \(hote.console.agent), vu \(age)."
      }
      return "On ne sait plus rien de cette machine."
    case .autre:
      return "Un NUC, un serveur, un Raspberry : tout ce qui a un terminal et joint le Relais."
    }
  }

  // MARK: Ce Mac

  @ViewBuilder
  private func ligneMoteurLocal(_ trouve: EngineCatalog.Finding) -> some View {
    SettingsRow(
      label: trouve.entry.labelFR,
      detail: detailMoteur(trouve),
      systemImage: iconeMoteur(trouve.state)
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
      } else if case .nonConnecte(let geste) = trouve.state {
        Button("Copier le geste") { copier(geste) }
      } else if enCours == trouve.entry.id {
        ProgressView().controlSize(.small)
      } else {
        HStack(spacing: Spacing.xs) {
          if let commande = trouve.entry.commandeInstallation,
             trouve.state == .nonInstalle, EngineInstaller.estLancable(commande)
          {
            Button("Installer") { Task { await installerMoteur(trouve, commande: commande) } }
              .disabled(enCours != nil)
          }
          Button("Copier la commande") { copier(trouve.entry.indiceInstallation) }
        }
      }
    }
  }

  private func iconeMoteur(_ state: EngineCatalog.State) -> String {
    switch state {
    case .pret: "checkmark.seal"
    case .nonConnecte: "person.crop.circle.badge.exclamationmark"
    case .adaptateurPerime: "exclamationmark.triangle"
    case .nonInstalle: "arrow.down.circle"
    }
  }

  /// Lance la commande épinglée, puis **rescanne** : c'est le disque qui dira
  /// « prêt », jamais le bouton. La sortie de la commande n'est montrée qu'en
  /// cas d'échec — quand ça passe, la carte change, et c'est toute la réponse.
  private func installerMoteur(_ trouve: EngineCatalog.Finding, commande: String) async {
    enCours = trouve.entry.id
    defer { enCours = nil }
    erreur = nil
    do {
      _ = try await EngineInstaller.installer(commande)
    } catch {
      erreur = error.localizedDescription
    }
    await rescannerLesMoteurs()
  }

  private func detailMoteur(_ trouve: EngineCatalog.Finding) -> String {
    var texte = trouve.state.labelFR
    if let path = trouve.path { texte += " · \(path)" }
    if case .nonConnecte(let geste) = trouve.state {
      texte += "\nLe binaire est là, la connexion pas encore : \(geste)"
    } else if !trouve.state.estPret {
      texte += "\n\(trouve.entry.indiceInstallation)"
    }
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

  // MARK: Une machine connue

  /// On ne propose que des moteurs **constatés là-bas** — proposer un moteur
  /// qu'on n'a vu nulle part serait une promesse.
  @ViewBuilder
  private func lignesHoteConnu(_ hote: HoteConnu) -> some View {
    SettingsRow(
      label: Self.nomEtAdresse(hote.nom, hote.adresse),
      detail: hote.adresse == nil
        ? "Adresse inconnue : son agent est d'avant cette version. Redéploie-le, et elle apparaîtra."
        : "Là où coller la commande, en SSH.",
      systemImage: "server.rack"
    ) {
      if enCours == "rescan:\(hote.console.agent)" {
        ProgressView().controlSize(.small)
      } else {
        Button("Rescanner") { Task { await rescannerLaBas(hote.console) } }
          .disabled(enCours != nil)
      }
    }

    ForEach(hote.disponibles, id: \.self) { moteur in
      let cle = "\(moteur)@\(hote.nom)"
      SettingsRow(
        label: EngineCatalog.entries.first { $0.id == moteur || $0.acpCommand == moteur }?.labelFR ?? moteur,
        detail: commandeDetail(cle: cle),
        systemImage: "checkmark.seal"
      ) {
        if let commande = commandes[cle]?.texte {
          Button("Copier") { copier(commande) }
        } else if enCours == cle {
          ProgressView().controlSize(.small)
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

    ForEach(hote.aConnecter, id: \.self) { moteur in
      let geste = EngineLogin.gesture(for: moteur) ?? "connecte-le dans un terminal là-bas."
      SettingsRow(
        label: EngineCatalog.entries.first { $0.id == moteur || $0.acpCommand == moteur }?.labelFR ?? moteur,
        detail: "installé là-bas, mais pas connecté : \(geste)",
        systemImage: "person.crop.circle.badge.exclamationmark"
      ) {
        Button("Copier le geste") { copier(geste) }
      }
    }

    if hote.disponibles.isEmpty, hote.aConnecter.isEmpty {
      SettingsRow(
        label: "Rien à ajouter",
        detail: hote.prets.isEmpty
          ? "Aucun moteur prêt là-bas. Installe-en un dans un terminal, connecte-le, puis « Rescanner »."
          : "Chaque moteur prêt là-bas porte déjà un agent.",
        systemImage: "checkmark.circle"
      )
    }
  }

  // MARK: Une autre machine

  @ViewBuilder
  private var lignesAutreMachine: some View {
    SettingsRow(
      label: "Moteur",
      detail: "Celui que l'agent lancera là-bas. Il doit y être installé et connecté ; l'agent le dira sinon.",
      systemImage: "engine.combustion"
    ) {
      Picker("", selection: $moteurAutre) {
        ForEach(EngineCatalog.entries) { entree in Text(entree.labelFR).tag(entree.id) }
      }
      .pickerStyle(.menu)
      .frame(width: 190)
    }

    SettingsRow(
      label: "Nom",
      detail: "Son compte sur le Relais, et ce qu'on tape pour l'appeler : « @\(nomAutreEffectif) ».",
      systemImage: "at"
    ) {
      TextField("nom", text: $nomAutre, prompt: Text(nomLibre(base: entreeAutre?.nomAgentPropose ?? moteurAutre)))
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
    }

    SettingsRow(
      label: "La commande",
      detail: commandeDetail(cle: "autre"),
      systemImage: "terminal"
    ) {
      if let commande = commandes["autre"]?.texte {
        Button("Copier") { copier(commande) }
      } else if enCours == "autre" {
        ProgressView().controlSize(.small)
      } else {
        Button("Préparer la commande") {
          Task {
            await preparerCommande(
              agent: nomAutreEffectif, cle: "autre",
              backend: entreeAutre?.backend.rawValue,
              acpCommand: entreeAutre?.acpCommand,
              acpArguments: entreeAutre?.acpArguments
            )
          }
        }
        .disabled(!peutProvisionner || enCours != nil || consoles.contains { $0.agent == nomAutreEffectif })
      }
    }
  }

  private var entreeAutre: EngineCatalog.Entry? { EngineCatalog.entries.first { $0.id == moteurAutre } }

  private var nomAutreEffectif: String {
    let saisi = nomAutre.trimmingCharacters(in: .whitespaces)
    return saisi.isEmpty ? nomLibre(base: entreeAutre?.nomAgentPropose ?? moteurAutre) : saisi
  }

  /// Ce qu'on dit d'une commande préparée — **jamais la commande elle-même** :
  /// elle contient le mot de passe du compte de l'agent, et un écran qui
  /// l'affiche finit dans une capture ou un copier-coller. Le bouton Copier
  /// est la seule façon de l'avoir.
  private func commandeDetail(cle: String) -> String {
    guard let commande = commandes[cle] else {
      return peutProvisionner
        ? "une commande à coller en SSH, et l'agent répond même Mac fermé"
        : "il faut être administrateur du Relais pour créer un agent"
    }
    guard commande.expire > Date() else { return "la commande a expiré — reprends-en une" }
    let heure = commande.expire.formatted(date: .omitted, time: .shortened)
    return "commande prête, copie-la et colle-la dans un terminal là-bas — elle contient un mot de passe "
      + "et périme à \(heure)"
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
    // Un agent pose ses clés de signature à son premier démarrage : à
    // l'activation il n'y avait rien à signer. On réessaie ici, à chaque
    // ouverture, jusqu'à ce que ça prenne — sans rien demander à personne.
    await store.attesterLesAgentsConnus()
  }

  /// L'ordre part dans la console ; l'agent rescanne à son prochain `/sync`
  /// et republie. On relit l'annuaire quelques secondes plus tard — et si le
  /// status n'a pas bougé, c'est que l'agent est muet, ce que la carte dit déjà.
  private func rescannerLaBas(_ console: MatrixBridgeService.AgentConsole) async {
    enCours = "rescan:\(console.agent)"
    defer { enCours = nil }
    erreur = nil
    guard await store.requestAgentRescan(console) else {
      erreur = "l'ordre de rescanner n'est pas parti — il est resté sur ce Mac"
      return
    }
    try? await Task.sleep(for: .seconds(4))
    await recharger()
  }

  /// Le scan seul, sans repasser par le Relais : c'est le disque de ce Mac
  /// qui a changé, pas l'annuaire.
  private func rescannerLesMoteurs() async {
    moteurs = await Task.detached { EngineCatalog.scan() }.value
    // Un agent pose ses clés de signature à son premier démarrage : à
    // l'activation il n'y avait rien à signer. On réessaie ici, à chaque
    // ouverture, jusqu'à ce que ça prenne — sans rien demander à personne.
    await store.attesterLesAgentsConnus()
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
