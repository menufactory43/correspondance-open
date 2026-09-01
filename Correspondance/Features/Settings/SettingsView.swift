import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Les Réglages tels qu'on les attend d'une app Mac : une barre latérale de
/// rubriques à gauche, un volet à droite. Pas un formulaire fleuve où l'on
/// scrolle pour trouver la case « Contacts ».
struct SettingsView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var section: SettingsSection = .comptes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(theme.separator)
      detail
    }
    .frame(
      minWidth: 840, idealWidth: 900, maxWidth: .infinity,
      minHeight: 620, idealHeight: 680, maxHeight: .infinity
    )
    .background(theme.paper)
    .background {
      SettingsWindowSizer(
        minSize: NSSize(width: 840, height: 620),
        idealSize: NSSize(width: 900, height: 680),
        title: "Réglages",
        isDark: theme.id.prefersDarkChrome
      )
      .frame(width: 0, height: 0)
    }
    .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
    .tint(theme.accent)
    .sheet(item: Binding(
      get: { store.bridgeLoginNetwork },
      set: { store.bridgeLoginNetwork = $0 }
    )) { network in
      BridgeLoginSheet(network: network)
    }
    .task { await store.refreshMatrixStatus() }
  }

  // MARK: - Barre latérale

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Réglages")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.inkTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xs)

      ForEach(SettingsSection.allCases) { item in
        sidebarButton(item)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.bottom, Spacing.sm)
    .frame(width: 208)
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxHeight: .infinity)
    .background(theme.sidebar.ignoresSafeArea())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Rubriques des réglages")
  }

  private func sidebarButton(_ item: SettingsSection) -> some View {
    let isSelected = section == item

    return Button {
      section = item
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: item.systemImage)
          .font(.system(size: 13))
          .frame(width: 20, alignment: .center)
          .foregroundStyle(isSelected ? theme.accent : theme.inkSecondary)
        Text(item.labelFR)
          .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.ink : theme.inkSecondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 7)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.selection)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  // MARK: - Volet

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        SettingsPaneHeader(title: section.labelFR, subtitle: section.subtitleFR)

        switch section {
        case .comptes: SettingsAccountsPane()
        case .matrix: SettingsMatrixPane()
        case .envoi: SettingsSendingPane()
        case .automatisation: SettingsAutomationPane()
        case .agent: SettingsAgentPane()
        case .autorisations: SettingsPermissionsPane()
        case .apparence: SettingsAppearancePane()
        case .dictee: SettingsDictationPane()
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.bottom, Spacing.xl)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(theme.paper.ignoresSafeArea())
  }
}

/// Les rubriques de la fenêtre — l'ordre ici est l'ordre de la barre latérale.
enum SettingsSection: String, CaseIterable, Identifiable {
  case comptes
  case matrix
  case envoi
  case automatisation
  case agent
  case autorisations
  case apparence
  case dictee

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .comptes: "Comptes"
    case .matrix: "Serveur Matrix"
    case .envoi: "Envoi"
    case .automatisation: "Automatisation"
    case .agent: "Agent"
    case .autorisations: "Autorisations"
    case .apparence: "Apparence"
    case .dictee: "Dictée"
    }
  }

  var subtitleFR: String {
    switch self {
    case .comptes: "Les réseaux branchés sur Correspondance et l’état de chaque lien."
    case .matrix: "Le homeserver qui porte les ponts WhatsApp et Instagram."
    case .envoi: "Le temps qu’un message reste rattrapable avant de partir."
    case .automatisation: "Piloter Messages en arrière-plan pour les actions qu’iMessage réserve à son app."
    case .agent: "Comment « cc » répond quand on l’appelle dans une conversation."
    case .autorisations: "Ce que macOS a accordé à Correspondance, et où le corriger."
    case .apparence: "Le mode d’ouverture, la police et l’ambiance d’écriture."
    case .dictee: "Le moteur qui transforme la voix en texte dans le composer."
    }
  }

  var systemImage: String {
    switch self {
    case .comptes: "person.2.fill"
    case .matrix: "server.rack"
    case .envoi: "paperplane"
    case .automatisation: "wand.and.stars"
    case .agent: "pencil.line"
    case .autorisations: "lock.shield"
    case .apparence: "paintbrush"
    case .dictee: "mic"
    }
  }
}

/// Les réglages de « cc » — et depuis la phase 1, ils vivent sur le Relais.
///
/// « cc » ne tourne pas dans l'app : c'est un processus à part, sur son hôte.
/// Ce que cet écran écrit part dans sa **room console** (event d'état
/// `fr.correspondance.agent.config`), qu'il relit à chaque `/sync` — d'où la
/// phrase du bas, qui dit que rien n'est instantané. Le mode brouillon/voix
/// haute continue d'être écrit *aussi* dans l'account data, une version encore,
/// pour un agent qui n'aurait pas été redéployé.
struct SettingsAgentPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var console: MatrixBridgeService.AgentConsole?
  @State private var isLoading = false
  @State private var isActivating = false
  @State private var erreur: String?
  /// L'état du service sur ce Mac — dont « à autoriser », qu'il faut montrer.
  @State private var hote: AgentLocalHost.State = .absent
  @State private var peutProvisionner = false
  /// La commande à coller sur une autre machine — vivante dix minutes.
  @State private var commandeDistante: String?
  @State private var commandeExpireA: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      consoleCard
      hoteCard

      hoteDistantCard

      if let console, let config = console.config {
        reglagesCard(console: console, config: config)
        journalCard(console: console)
      }

      Text(console == nil
        ? "Tant que la console n'existe pas, cc tourne sur le fichier de sa machine."
        : "Le réglage part sur le Relais ; cc le relit à sa prochaine synchronisation.")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(themes.theme.inkTertiary)
    }
    .task { await recharger() }
  }

  // MARK: - Où tourne cc

  private var consoleCard: some View {
    SettingsCard(
      title: "cc",
      footnote: "Les moteurs vivent là où cc tourne, pas sur ce Mac. "
        + "Il scanne sa machine à son démarrage et publie ce qu'il y trouve."
    ) {
      SettingsRow(
        label: "État",
        detail: etatDetail,
        systemImage: "cpu"
      ) {
        if isLoading || isActivating {
          ProgressView().controlSize(.small)
        } else if console == nil {
          Button("Activer cc") { Task { await activer() } }
        } else {
          Button("Rafraîchir") { Task { await recharger() } }
        }
      }
    }
  }

  /// L'hôte « Ce Mac » : l'agent tourne **dans** l'app, comme processus
  /// enfant. On le dit sans détour — quitter l'app arrête cc, et pour un cc
  /// joignable jour et nuit c'est l'hôte distant qu'il faut.
  private var hoteCard: some View {
    SettingsCard(
      title: "Sur ce Mac",
      footnote: "cc tourne tant que Correspondance est ouverte, sur le `claude` déjà connecté ici. "
        + "Pour qu'il réponde jour et nuit, installe-le sur une autre machine — juste en dessous."
    ) {
      SettingsRow(
        label: "cc",
        detail: hote.labelFR(agent: store.agentName),
        systemImage: "cpu"
      ) {
        // Chaque état a une sortie. Un écran qui affiche un fait sans offrir
        // d'action est un cul-de-sac : c'est exactement ce qui s'est produit
        // quand macOS a dit « enregistré » alors que rien n'existait.
        switch hote {
        case .actif, .silencieux:
          Button("Arrêter") { desactiver() }
        case .incomplet, .abandonne:
          Button("Réparer") { Task { await reparerLocalement() } }
            .disabled(!peutProvisionner || isActivating)
        case .absent:
          // L'amorce est là (sinon l'état serait « incomplet ») : on relance,
          // on ne refait pas le compte.
          Button("Démarrer cc") { Task { await demarrerLocalement() } }
            .disabled(isActivating)
        case .introuvable:
          // Rien à activer, mais on ne laisse pas sans issue : on dit ce qu'on
          // a constaté, pas ce qu'on suppose.
          Button("Pourquoi ?") { erreur = AgentLocalHost.aideIntrouvable }
        }
      }

      // Un seul énoncé du même fait. Deux lignes qui se contredisent — « il n'a
      // pas encore publié » au-dessus de « il n'a rien publié depuis un
      // moment » — sont pires qu'une seule ligne fausse : on ne sait plus
      // laquelle croire. La ligne du dessous n'apparaît donc que pour un
      // silence *daté*, et elle ne redit pas ce que l'état vient de dire.
      if case .silencieux(let depuis) = hote, depuis != nil {
        SettingsRow(
          label: "Journal",
          detail: "Son journal dira pourquoi il s'est tu.",
          systemImage: "waveform.path"
        ) { journalBouton }
      }

      if hote == .incomplet {
        SettingsRow(
          label: "Ce qui manque",
          detail: "L'amorce de cc n'est pas sur le disque : il ne peut pas se connecter au Relais. "
            + "« Réparer » recrée le compte, l'amorce et relance.",
          systemImage: "exclamationmark.triangle"
        ) { EmptyView() }
      }

      if case .abandonne = hote {
        SettingsRow(
          label: "Journal",
          detail: "cc est retombé trop de fois de suite — on a cessé de le relancer.",
          systemImage: "doc.text.magnifyingglass"
        ) { journalBouton }
      }
    }
  }

  @ViewBuilder
  private var journalBouton: some View {
    if let url = AgentLocalHost.logURL(agent: store.agentName) {
      Button("Ouvrir le journal") { NSWorkspace.shared.open(url) }
    } else {
      EmptyView()
    }
  }

  /// L'hôte distant : un NUC, un VPS, un Raspberry. L'app crée le compte et
  /// rend **une** commande à coller — elle ne peut pas aller installer un
  /// binaire chez quelqu'un, et elle ne prétend pas le faire. C'est aussi la
  /// seule réponse à « je veux que cc réponde quand mon Mac est fermé ».
  private var hoteDistantCard: some View {
    SettingsCard(
      title: "Sur une autre machine",
      footnote: "24/7, Mac fermé. La commande contient le mot de passe de l'agent : "
        + "elle se colle dans un terminal, jamais dans une conversation. Elle périme en dix minutes."
    ) {
      SettingsRow(
        label: "Hôte distant",
        detail: commandeDetail,
        systemImage: "server.rack"
      ) {
        if let commandeDistante {
          Button("Copier") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commandeDistante, forType: .string)
          }
        } else {
          Button("Préparer la commande") { Task { await preparerCommande() } }
            .disabled(!peutProvisionner)
        }
      }
    }
  }

  private var commandeDetail: String {
    guard let commandeDistante else {
      return peutProvisionner
        ? "une commande à coller en SSH, et cc répond même Mac fermé"
        : "il faut être administrateur du Relais pour créer un agent"
    }
    if let expire = commandeExpireA, expire <= Date() {
      return "la commande a expiré — reprends-en une"
    }
    return commandeDistante
  }

  private var etatDetail: String {
    if let erreur { return erreur }
    guard let console else { return "pas encore de console — cc tourne sur son fichier" }
    guard let status = console.status else { return "console ouverte ; cc n'a encore rien publié" }
    let age = status.publishedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
    return "\(status.engines) — \(age)"
  }

  // MARK: - Ce que cc a le droit de faire

  private func reglagesCard(console: MatrixBridgeService.AgentConsole, config: AgentConsoleConfig) -> some View {
    SettingsCard(
      title: "Réglages de cc",
      footnote: "cc travaille dans un dossier par conversation — jamais ta maison — "
        + "tant qu'aucun dépôt n'y est lié. C'est ce qui borne ce qu'il peut atteindre."
    ) {
      SettingsRow(
        label: "Outils",
        detail: (AgentConsoleConfig.ToolPreset(rawValue: config.toolPreset ?? "")?.subtitleFR)
          ?? "réglés à la main sur sa machine",
        systemImage: "wrench.and.screwdriver"
      ) {
        Picker("", selection: Binding(
          get: { AgentConsoleConfig.ToolPreset(rawValue: config.toolPreset ?? "") ?? .executer },
          set: { palier in
            Task { await ecrire(console: console) { $0.toolPreset = palier.rawValue } }
          }
        )) {
          ForEach(AgentConsoleConfig.ToolPreset.allCases) { palier in
            Text(palier.labelFR).tag(palier)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 220)
      }

      SettingsRow(
        label: "Voix par défaut",
        detail: (config.defaultMode ?? store.agentDefaultMode).subtitleFR
          + " — une conversation peut dire autrement, sous son « + ».",
        systemImage: "person.2.wave.2"
      ) {
        Picker("", selection: Binding(
          get: { config.defaultMode ?? store.agentDefaultMode },
          set: { mode in
            // L'account data reste écrite une version encore : un agent pas
            // redéployé ne lit que celle-là.
            store.setAgentDefaultMode(mode)
            Task { await ecrire(console: console) { $0.defaultMode = mode } }
          }
        )) {
          Text("Brouillon à valider").tag(AgentSettings.Mode.draft)
          Text("À voix haute").tag(AgentSettings.Mode.direct)
        }
        .pickerStyle(.menu)
        .frame(width: 190)
      }

      SettingsRow(
        label: "Demandes par heure",
        detail: "au-delà, cc répond qu'il faut attendre",
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
  }

  // MARK: - Ce que cc a fait

  private func journalCard(console: MatrixBridgeService.AgentConsole) -> some View {
    SettingsCard(
      title: "Derniers tours",
      footnote: console.journal.isEmpty
        ? "cc n'a encore rien fait depuis que sa console existe."
        : "Chaque tour laisse une trace ici : qui a demandé, quels outils ont servi, combien de temps."
    ) {
      ForEach(console.journal.prefix(6)) { tour in
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

  // MARK: -

  private func recharger() async {
    isLoading = true
    defer { isLoading = false }
    erreur = nil
    console = await store.loadAgentConsole()
    // L'état ne se lit pas dans macOS : il se conclut. Le dernier status publié
    // par l'agent dans sa console est le seul vrai signe de vie.
    hote = AgentLocalHost.state(agent: store.agentName, dernierStatus: console?.status?.publishedAt)
    peutProvisionner = await store.canProvisionAgents()
  }

  private func desactiver() {
    store.deactivateAgentOnThisMac()
    Task { await recharger() }
  }

  /// « Réparer » : on désenregistre d'abord, puis on refait tout. Sans le
  /// désenregistrement, macOS garde son drapeau et on repart dans le même
  /// demi-état.
  private func reparerLocalement() async {
    AgentLocalHost.reset(agent: store.agentName)
    await activerLocalement()
  }

  /// Crée le compte du bot, pose son amorce, enregistre le service. macOS peut
  /// demander une approbation : on la montre, on ne l'espère pas.
  /// Relance l'agent avec son amorce. Si elle manque malgré l'état, on refait
  /// le chemin complet — mais on ne le fait jamais par défaut.
  private func demarrerLocalement() async {
    isActivating = true
    defer { isActivating = false }
    erreur = nil
    guard AgentLocalHost.resume(agent: store.agentName, force: true) != nil else {
      await activerLocalement()
      return
    }
    await attendreQuIlParle()
  }

  private func attendreQuIlParle() async {
    await recharger()
    for _ in 0..<6 {
      if case .actif = hote { break }
      try? await Task.sleep(for: .seconds(2))
      await recharger()
    }
  }

  private func activerLocalement() async {
    isActivating = true
    defer { isActivating = false }
    erreur = nil
    switch await store.activateAgentOnThisMac() {
    case .success:
      // On ne garde pas l'état rendu par l'installation : il ne connaît pas le
      // status de l'agent, qui n'a pas encore eu le temps de parler.
      await recharger()
      // Et on attend qu'il parle. Sans ça, l'écran reste sur « il n'a pas
      // encore publié » jusqu'à ce qu'on le rouvre — alors que l'agent s'est
      // annoncé cinq secondes plus tard. Six essais, dix secondes en tout :
      // au-delà, c'est un vrai problème et l'état le dira.
      for _ in 0..<6 {
        if case .actif = hote { break }
        try? await Task.sleep(for: .seconds(2))
        await recharger()
      }
    case .failure(let raison):
      erreur = raison.localizedDescription
    }
  }

  private func activer() async {
    isActivating = true
    defer { isActivating = false }
    erreur = nil
    guard let ouverte = await store.activateAgentConsole() else {
      erreur = "le Relais n'a pas voulu ouvrir la console"
      return
    }
    console = ouverte
  }

  /// Crée le compte du bot et rend la commande d'installation. Le jeton porte
  /// l'amorce : il n'y a pas de serveur pour la servir, et c'est sa péremption
  /// courte qui borne la fuite.
  private func preparerCommande() async {
    isActivating = true
    defer { isActivating = false }
    erreur = nil
    switch await store.remoteAgentToken() {
    case .success(let jeton):
      commandeDistante = jeton.installCommand()
      commandeExpireA = jeton.expiresAt
    case .failure(let raison):
      erreur = raison.localizedDescription
    }
  }

  /// Corrige la config et l'écrit. On recharge derrière : ce que l'écran montre
  /// est ce que le Relais porte, pas ce qu'on aurait aimé y mettre.
  private func ecrire(
    console: MatrixBridgeService.AgentConsole,
    _ mutation: (inout AgentConsoleConfig) -> Void
  ) async {
    guard var config = console.config else { return }
    mutation(&config)
    let parti = await store.writeAgentConsoleConfig(config, in: console.roomID)
    if !parti { erreur = "le réglage n'est pas parti — il est resté sur ce Mac" }
    await recharger()
  }
}
