import SwiftUI

/// Nouvelle conversation iMessage / Signal — contact ou numéro / e-mail.
struct NewConversationSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork = .iMessage
  @State private var query = ""
  @State private var hits: [ContactDirectory.DirectoryHit] = []
  @State private var isSearching = false

  private var theme: WritingTheme { themes.theme }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// WhatsApp n'apparaît que si le homeserver répond : sinon le bouton ne mènerait nulle part.
  private var availableNetworks: [MessageNetwork] {
    MessageNetwork.allCases.filter { !$0.isMatrixBridged || store.isMatrixConnected }
  }

  private var canWriteFreeform: Bool {
    let value = trimmedQuery
    guard !value.isEmpty else { return false }
    // Le bridge WhatsApp ne prend qu'un numéro (commande bot `pm`).
    if network.isMatrixBridged { return value.filter(\.isNumber).count >= 8 }
    if value.contains("@") { return value.contains(".") }
    return value.filter(\.isNumber).count >= 8
  }

  /// Une adresse e-mail n'a aucun sens sur WhatsApp.
  private func canCompose(_ handle: String) -> Bool {
    guard network.isMatrixBridged else { return true }
    return handle.filter(\.isNumber).count >= 8 && !handle.contains("@")
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

      TextField(network.isMatrixBridged ? "Numéro WhatsApp" : "Nom, numéro ou e-mail", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .onChange(of: query) { _, _ in
          Task { await refreshHits() }
        }

      List {
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
    .task { await refreshHits() }
  }

  private var header: some View {
    HStack {
      Text("Nouvelle conversation")
        .font(.headline)
      Spacer()
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
