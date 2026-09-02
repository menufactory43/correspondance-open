import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Nouvelle conversation : contact, numéro, e-mail — ou pseudo pour un pont qui
/// ne connaît pas les numéros (Instagram).
struct NewConversationSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork = .iMessage
  @State private var query = ""
  @State private var hits: [ContactDirectory.DirectoryHit] = []
  @State private var isSearching = false
  @State private var isCreatingGroup = false

  private var theme: WritingTheme { themes.theme }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Un réseau bridgé n'apparaît que si le homeserver répond : sinon le bouton ne mènerait nulle part.
  private var availableNetworks: [MessageNetwork] {
    MessageNetwork.allCases.filter { $0 != .agent && (!$0.isMatrixBridged || store.isMatrixConnected) }
  }

  /// Les agents du Relais, comme des contacts : un tête-à-tête s'ouvre d'un
  /// clic, sans passer par la note à soi. Filtrés par ce qu'on tape.
  private var agents: [String] {
    guard store.isMatrixConnected else { return [] }
    let q = trimmedQuery.lowercased()
    return store.agentDirectory.filter { q.isEmpty || $0.lowercased().contains(q) }
  }

  /// Ce que le réseau attend dans le champ. WhatsApp se compose, Instagram et
  /// Messenger se nomment.
  private var placeholderFR: String {
    switch network {
    case .whatsapp: "Numéro WhatsApp"
    case .signal: "Numéro Signal"
    case .instagram: "Nom d’utilisateur Instagram"
    case .messenger: "Nom ou identifiant Messenger"
    default: "Nom, numéro ou e-mail"
    }
  }

  private var canWriteFreeform: Bool {
    let value = trimmedQuery
    guard !value.isEmpty else { return false }
    return isValidHandle(value)
  }

  /// Un numéro ne se réduit pas à un pseudo, ni l'inverse : chaque réseau a sa règle.
  private func isValidHandle(_ handle: String) -> Bool {
    switch network {
    // WhatsApp et Signal ne prennent qu'un numéro (commande bot `pm +33…`).
    // Une adresse e-mail y échouerait côté bot, sans rien dire de lisible ici.
    case .whatsapp, .signal:
      return handle.filter(\.isNumber).count >= 8 && !handle.contains("@")
    // Instagram et Messenger : un pseudo ou un identifiant Meta. Pas d'arobase à
    // l'intérieur — celle de tête, l'usage la met, on la retire à l'envoi.
    case .instagram, .messenger:
      let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
      return !bare.isEmpty && !bare.contains("@") && !bare.contains(" ")
    default:
      if handle.contains("@") { return handle.contains(".") }
      return handle.filter(\.isNumber).count >= 8
    }
  }

  /// Les contacts du carnet d'adresses n'ont rien à proposer à un réseau sans numéros.
  private func canCompose(_ handle: String) -> Bool {
    isValidHandle(handle)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      Picker("Réseau", selection: $network) {
        ForEach(availableNetworks) { item in
          Text(item.labelFR).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: store.isMatrixConnected) { _, connected in
        if !connected && network.isMatrixBridged { network = .iMessage }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      TextField(placeholderFR, text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .onChange(of: query) { _, _ in
          Task { await refreshHits() }
        }

      List {
        if !agents.isEmpty {
          Section("Agents") {
            ForEach(agents, id: \.self) { agent in
              Button {
                Task {
                  await store.openAgentConversation(agent: agent)
                  dismiss()
                }
              } label: {
                Label {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(agent).foregroundStyle(theme.ink)
                    Text("agent sur le Relais — il répond à tout ce que tu lui écris")
                      .font(.caption)
                      .foregroundStyle(theme.inkSecondary)
                  }
                } icon: {
                  Image(systemName: MessageNetwork.agent.systemImage)
                }
              }
            }
          }
        }

        if canWriteFreeform && !hits.contains(where: { $0.handle.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
          Button {
            compose(handle: trimmedQuery, title: trimmedQuery)
          } label: {
            Label("Écrire à \(trimmedQuery)", systemImage: "square.and.pencil")
          }
        }

        ForEach(hits.filter { canCompose($0.handle) }) { hit in
          Button {
            compose(handle: hit.handle, title: hit.name)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(hit.name)
                .foregroundStyle(theme.ink)
              Text(hit.handle)
                .font(.caption)
                .foregroundStyle(theme.inkSecondary)
            }
          }
        }
      }
      .listStyle(.inset)
    }
    .frame(minWidth: 420, minHeight: 460)
    .background(theme.paper)
    .task {
      await store.refreshAgentDirectory()
      await refreshHits()
    }
    .sheet(isPresented: $isCreatingGroup) {
      NewGroupSheet()
        .environment(store)
        .environment(themes)
    }
  }

  private var header: some View {
    HStack {
      Text("Nouvelle conversation")
        .font(.headline)
      Spacer()
      // Le geste vit aussi dans le menu (⌥⌘N), mais c'est ICI qu'on le
      // cherche : « écrire à quelqu'un » et « écrire à plusieurs » sont la
      // même intention. Absent si aucun pont branché ne sait le faire.
      if store.canCreateGroup {
        Button("Nouveau groupe…") { isCreatingGroup = true }
      }
      Button("Fermer") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(Spacing.md)
  }

  private func refreshHits() async {
    isSearching = true
    let found = await ContactDirectory.shared.searchPeople(query: query)
    hits = found
    isSearching = false
  }

  private func compose(handle: String, title: String) {
    Task {
      await store.openOrCreateConversation(
        network: network,
        handle: handle,
        title: title
      )
      dismiss()
    }
  }
}
