import SwiftUI
import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceUI

/// Les trois modèles de cadre du mode « répond seul » : une phrase qui dit
/// ce que cc a le droit de faire seul dans ce fil, et quand passer la main.
enum AgentPilotTemplates {
  struct Template: Identifiable {
    let title: String
    let text: String
    var id: String { title }
  }

  static let all: [Template] = [
    Template(
      title: "Vendeur Marketplace",
      text: "Dis que c'est disponible au prix annoncé, propose une remise en main propre ce week-end. "
        + "Si on parle de livraison ou de baisser le prix, passe-moi la main."
    ),
    Template(
      title: "Accueil client",
      text: "Réponds aux questions sur les horaires, l'adresse et les tarifs affichés. "
        + "Pour une réservation, une réclamation ou un devis, passe-moi la main."
    ),
    Template(
      title: "Famille",
      text: "Réponds aux questions pratiques — où je suis, à quelle heure je rentre, qui vient dîner — avec ce que tu sais. "
        + "Pour tout ce qui engage, argent, santé, décisions, passe-moi la main."
    ),
  ]
}

/// La carte **Assistant** de la fiche d'un fil : ce que cc fait ici, en trois
/// positions — Sur demande / Propose / Répond seul — et, en « Répond seul »,
/// le cadre dans lequel il a le droit d'agir. Absente quand aucun agent n'est
/// dans le fil.
///
/// Chaque position est deux réglages de la console de l'agent
/// (`RoomBinding.mode` et `.suggest`) : « Sur demande » = brouillon sans
/// proposition spontanée ; « Propose » = brouillon, proposition à chaque
/// message reçu ; « Répond seul » = `pilot`. Les deux s'écrivent d'un coup.
/// Rien ne s'affiche qui n'ait quitté l'app : une position qui n'est pas
/// partie revient.
struct AssistantSection: View {
  let conversation: Conversation
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  /// Un réglage par agent présent — une section chacun, dans l'ordre des noms.
  @State private var agents: [AssistantSettings] = []

  var body: some View {
    // Le `.task` vit sur une pile toujours présente : posé sur un
    // `Color.clear` de hauteur nulle, il ne partait jamais, et la carte ne
    // savait donc jamais que cc était là (vu dans la vraie Note à soi).
    VStack(alignment: .leading, spacing: 0) {
      ForEach(agents, id: \.agent) { settings in
        AssistantAgentSection(conversation: conversation, settings: settings, theme: theme)
      }
    }
    .task(id: conversation.id) {
      guard conversation.network.livesOnRelay else { agents = []; return }
      agents = await store.assistantSettingsInSelectedConversation()
    }
  }
}

/// La section d'UN agent dans la carte Assistant : son segment, son cadre.
/// Ce qu'elle écrit ne touche que **sa** console ; le relais du pont, lui,
/// se décide sur l'ensemble des agents du fil (`voixHauteDansLeFil`).
struct AssistantAgentSection: View {
  let conversation: Conversation
  let settings: AssistantSettings
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  private var agent: String? { settings.agent }
  @State private var posture: Posture = .onDemand
  @State private var frame = ""
  @State private var isWriting = false
  /// Compte les gestes de l'utilisateur : une lecture partie avant un clic
  /// ne doit pas le recouvrir en arrivant après — c'était le segment qui
  /// « revenait » et qu'il fallait cliquer plusieurs fois.
  @State private var edits = 0
  @FocusState private var frameFocused: Bool

  enum Posture: String, CaseIterable, Identifiable {
    case onDemand, propose, pilot
    var id: String { rawValue }

    var labelFR: String {
      switch self {
      case .onDemand: "Sur demande"
      case .propose: "Propose"
      case .pilot: "Répond seul"
      }
    }

    func subtitleFR(agent: String) -> String {
      switch self {
      case .onDemand:
        "\(agent) ne fait rien tant que tu ne lui demandes pas — @\(agent) dans le fil, ou en aparté. "
          + "Ce qu'il écrit reste un brouillon que toi seul vois."
      case .propose:
        "À chaque message reçu, \(agent) prépare une réponse que toi seul vois. "
          + "Tu l'envoies, la retouches ou l'ignores."
      case .pilot:
        "\(agent) répond lui-même, en ton nom, dans le cadre ci-dessous. "
          + "Chaque réponse est marquée. Hors cadre, il te passe la main."
      }
    }

    static func from(mode: AgentSettings.Mode, suggest: String?) -> Posture {
      if mode == .pilot { return .pilot }
      if let suggest, suggest != AgentWire.Suggest.off { return .propose }
      return .onDemand
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let agent {
        Divider()
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: 6) {
            Image(systemName: "sparkles")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(posture == .pilot ? Color.red : theme.accent)
            Text("Assistant")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(agent)
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }

          Picker("Ce que \(agent) fait ici", selection: Binding(
            get: { posture },
            set: { apply($0) }
          )) {
            ForEach(Posture.allCases) { position in
              Text(position.labelFR)
                .foregroundStyle(position == .pilot ? Color.red : theme.ink)
                .tag(position)
            }
          }
          .pickerStyle(.segmented)
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .labelsHidden()
          .disabled(isWriting)
          // Le segment « Répond seul » se teinte en rouge quand il est choisi.
          .tint(posture == .pilot ? Color.red : theme.accent)

          Text(posture.subtitleFR(agent: agent))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if posture == .pilot {
            frameEditor(agent: agent)
          }
        }
      }
    }
    .task(id: settings) { load() }
  }

  // MARK: - Le cadre

  /// Le modèle dont le cadre est le texte, s'il en est un — sinon c'est le
  /// tien.
  private var currentTemplate: AgentPilotTemplates.Template? {
    AgentPilotTemplates.all.first { $0.text == frame.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  /// Le cadre : un menu de modèles pour partir de quelque chose, et le texte
  /// entier, modifiable, dans un champ qui grandit avec lui. Un modèle est un
  /// point de départ, pas une liste fermée : on le réécrit librement.
  @ViewBuilder
  private func frameEditor(agent: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Cadre")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Menu {
        ForEach(AgentPilotTemplates.all) { template in
          Button(template.title) {
            frame = template.text
            saveFrame()
          }
        }
        Divider()
        Button("Écrire le mien") {
          frame = ""
          frameFocused = true
        }
      } label: {
        HStack(spacing: 3) {
          Text(currentTemplate?.title ?? (frame.isEmpty ? "Choisir un modèle" : "Le mien"))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.accent)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Modèle de cadre")
    }
    .padding(.top, 2)

    // Le champ prend la hauteur du texte : un `Text` invisible le mesure, le
    // `TextEditor` se pose dessus. Le `TextField` vertical restait bloqué à
    // deux lignes et coupait le cadre au milieu d'une phrase (vu à l'écran).
    ZStack(alignment: .topLeading) {
      Text(frame.isEmpty ? " " : frame)
        .font(.system(size: 12))
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
      if frame.isEmpty {
        Text("Ce que \(agent) peut faire seul ici, et quand te passer la main.")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 5)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
      }
      TextEditor(text: $frame)
        .font(.system(size: 12))
        .foregroundStyle(theme.ink)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(.vertical, 8)
        .focused($frameFocused)
        .onChange(of: frameFocused) { _, focused in
          if !focused { saveFrame() }
        }
        .accessibilityLabel("Cadre de \(agent)")
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.paperSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(frameFocused ? Color.red.opacity(0.5) : theme.edge, lineWidth: 0.8)
    )

    Text("Écris-le comme tu le dirais à quelqu'un qui répond à ta place. Enregistré en quittant le champ.")
      .font(.system(size: 10))
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Lire, écrire

  /// Qui est là, de quelle voix, avec quel cadre — une lecture, et elle ne
  /// recouvre pas un clic donné entre-temps.
  private func load() {
    // Une relecture ne recouvre jamais un clic donné entre-temps.
    guard edits == 0 else { return }
    posture = Posture.from(mode: settings.mode, suggest: settings.binding.suggest)
    frame = settings.binding.frame ?? ""
  }

  private func apply(_ wanted: Posture) {
    guard let agent, wanted != posture, !isWriting else { return }
    let before = posture
    posture = wanted
    edits += 1
    isWriting = true
    Task {
      defer { isWriting = false }
      let ok: Bool = switch wanted {
      case .onDemand:
        await store.setAgentPosture(.draft, suggest: AgentWire.Suggest.off, agent: agent) != nil
      case .propose:
        await store.setAgentPosture(.draft, suggest: AgentWire.Suggest.always, agent: agent) != nil
      case .pilot:
        await store.setAgentPosture(.pilot, suggest: nil, agent: agent) != nil
      }
      // Ce qui n'est pas parti ne s'affiche pas.
      if !ok { posture = before }
    }
  }

  private func saveFrame() {
    guard let agent, posture == .pilot else { return }
    edits += 1
    Task { await store.setAgentFrame(frame, agent: agent) }
  }
}
