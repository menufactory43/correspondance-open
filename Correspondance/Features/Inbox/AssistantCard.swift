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
/// message reçu ; « Répond seul » = `pilot`. Rien ne s'affiche qui n'ait
/// quitté l'app : la position ne bouge qu'une fois la console réécrite.
struct AssistantSection: View {
  let conversation: Conversation
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  @State private var agent: String?
  @State private var posture: Posture = .onDemand
  @State private var frame = ""
  @State private var isWriting = false
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

    var subtitleFR: String {
      switch self {
      case .onDemand: AgentSettings.Mode.draft.subtitleFR
      case .propose: "À chaque message reçu, il prépare une réponse que vous seul voyez."
      case .pilot: AgentSettings.Mode.pilot.subtitleFR
      }
    }

    static func from(mode: AgentSettings.Mode, suggest: String?) -> Posture {
      if mode == .pilot { return .pilot }
      if let suggest, suggest != AgentWire.Suggest.off { return .propose }
      return .onDemand
    }
  }

  var body: some View {
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

        Text(posture.subtitleFR)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if posture == .pilot {
          Text("Cadre")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
          TextField(
            "Ce que \(agent) peut faire seul ici, et quand te passer la main",
            text: $frame,
            axis: .vertical
          )
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .lineLimit(2...6)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(theme.paperSecondary)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(frameFocused ? Color.red.opacity(0.5) : theme.edge, lineWidth: 0.8)
          )
          .focused($frameFocused)
          .onSubmit { saveFrame() }
          .onChange(of: frameFocused) { _, focused in
            if !focused { saveFrame() }
          }

          // Trois modèles : un clic remplit le cadre et l'écrit.
          HStack(spacing: 6) {
            ForEach(AgentPilotTemplates.all) { template in
              Button(template.title) {
                frame = template.text
                saveFrame()
              }
              .buttonStyle(.plain)
              .font(.system(size: 11))
              .foregroundStyle(frame == template.text ? Color.red : theme.inkSecondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                Capsule(style: .continuous)
                  .fill(frame == template.text ? Color.red.opacity(0.12) : theme.paperSecondary)
              )
              .overlay(Capsule(style: .continuous).stroke(theme.edge, lineWidth: 0.8))
            }
          }
        }
      }
      .task(id: conversation.id) { await load() }
    } else {
      // Rien tant qu'on ne sait pas : la fiche ne montre pas une carte vide.
      Color.clear.frame(height: 0)
        .task(id: conversation.id) { await load() }
    }
  }

  /// Qui est là, et de quelle voix — relu depuis le Relais.
  private func load() async {
    guard conversation.network.livesOnRelay else { agent = nil; return }
    let voices = await store.agentVoicesInSelectedConversation()
    guard let voice = voices.first else { agent = nil; return }
    let binding = await store.agentRoomBinding(agent: voice.agent) ?? AgentConsoleConfig.RoomBinding()
    agent = voice.agent
    posture = Posture.from(mode: voice.mode, suggest: binding.suggest)
    frame = binding.frame ?? ""
  }

  private func apply(_ wanted: Posture) {
    guard let agent, wanted != posture else { return }
    let before = posture
    posture = wanted
    isWriting = true
    Task {
      defer { isWriting = false }
      var ok = true
      switch wanted {
      case .onDemand:
        if before == .pilot { ok = await store.setAgentVoice(.draft, agent: agent) != nil }
        if ok { ok = await store.setAgentSuggest(AgentWire.Suggest.off, agent: agent) }
      case .propose:
        if before == .pilot { ok = await store.setAgentVoice(.draft, agent: agent) != nil }
        if ok { ok = await store.setAgentSuggest(AgentWire.Suggest.always, agent: agent) }
      case .pilot:
        ok = await store.setAgentVoice(.pilot, agent: agent) != nil
      }
      // Ce qui n'est pas parti ne s'affiche pas.
      if !ok { posture = before }
    }
  }

  private func saveFrame() {
    guard let agent, posture == .pilot else { return }
    Task { await store.setAgentFrame(frame, agent: agent) }
  }
}
