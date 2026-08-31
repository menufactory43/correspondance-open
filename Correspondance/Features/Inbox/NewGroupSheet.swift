import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Créer un groupe sur un réseau, depuis l'app.
///
/// Deux ponts seulement le savent faire (`NetworkCapabilities.createsGroup`) :
/// le sélecteur de réseau n'en montre pas d'autre, et le geste n'existe pas si
/// aucun n'est branché. Le nom part avec le salon — c'est lui que le pont lit.
struct NewGroupSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork = .whatsapp
  @State private var name = ""
  @State private var participant = ""
  @State private var participants: [String] = []
  @State private var isCreating = false

  private var theme: WritingTheme { themes.theme }

  private var availableNetworks: [MessageNetwork] {
    MessageNetwork.allCases.filter {
      $0.capabilities.createsGroup && store.isMatrixConnected && store.hasConversations(on: $0)
    }
  }

  /// Signal borne le nom d'un groupe à 32 signes. On le dit avant, pas après.
  private var nameLimit: Int { network == .signal ? 32 : 100 }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var canCreate: Bool {
    !trimmedName.isEmpty && trimmedName.count <= nameLimit && !participants.isEmpty && !isCreating
  }

  private var participantPromptFR: String {
    network == .signal ? "Identifiant Signal (UUID)" : "Numéro au format international"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Nouveau groupe").font(.headline)
        Spacer()
        Button("Fermer") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }

      Picker("Réseau", selection: $network) {
        ForEach(availableNetworks) { item in
          Text(item.labelFR).tag(item)
        }
      }
      .pickerStyle(.segmented)

      TextField("Nom du groupe", text: $name)
        .textFieldStyle(.roundedBorder)
      if trimmedName.count > nameLimit {
        Text("\(network.labelFR) n’accepte pas plus de \(nameLimit) caractères.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.accent)
      }

      HStack(spacing: 6) {
        TextField(participantPromptFR, text: $participant)
          .textFieldStyle(.roundedBorder)
          .onSubmit { addParticipant() }
        Button("Ajouter", action: addParticipant)
          .disabled(participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      List {
        ForEach(participants, id: \.self) { item in
          HStack {
            Text(item).foregroundStyle(theme.ink)
            Spacer(minLength: 4)
            Button("Retirer") { participants.removeAll { $0 == item } }
              .buttonStyle(.borderless)
              .font(Typography.meta(themes.typeface))
          }
        }
      }
      .listStyle(.inset)
      .frame(maxHeight: .infinity)

      Text("Le groupe est créé sur \(network.labelFR) : les autres membres le verront apparaître chez eux.")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)

      HStack {
        Spacer()
        if isCreating { ProgressView().controlSize(.small) }
        Button("Créer le groupe") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(Spacing.md)
    .frame(width: 420, height: 460)
    .background(theme.paper)
    .onAppear {
      if let first = availableNetworks.first, !availableNetworks.contains(network) {
        network = first
      }
    }
  }

  private func addParticipant() {
    let value = participant.trimmingCharacters(in: .whitespacesAndNewlines)
    participant = ""
    guard !value.isEmpty, !participants.contains(value) else { return }
    participants.append(value)
  }

  private func create() {
    guard canCreate else { return }
    isCreating = true
    let target = network
    let title = trimmedName
    let people = participants
    Task {
      await store.createGroup(network: target, name: title, identifiers: people)
      isCreating = false
      dismiss()
    }
  }
}
