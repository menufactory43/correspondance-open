import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Créer un groupe sur un réseau, depuis l'iPhone.
///
/// Deux ponts seulement le savent faire (`NetworkCapabilities.createsGroup`) :
/// le sélecteur de réseau n'en montre pas d'autre, et le geste n'existe pas si
/// aucun n'est branché. Le nom part avec le salon — c'est lui que le pont lit.
struct NewGroupSheet: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork = .whatsapp
  @State private var name = ""
  @State private var participant = ""
  @State private var participants: [String] = []
  @State private var isCreating = false
  @State private var failure: String?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var availableNetworks: [MessageNetwork] {
    MessageNetwork.allCases.filter { candidate in
      candidate.capabilities.createsGroup
        && store.conversations.contains { $0.network == candidate }
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
    NavigationStack {
      List {
        if availableNetworks.count > 1 {
          Section {
            Picker("Réseau", selection: $network) {
              ForEach(availableNetworks) { item in
                Text(item.labelFR).tag(item)
              }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
          }
        }

        Section {
          TextField("Nom du groupe", text: $name)
            .font(Typography.composer(typeface))
            .foregroundStyle(theme.ink)
          if trimmedName.count > nameLimit {
            Text("\(network.labelFR) n’accepte pas plus de \(nameLimit) caractères.")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.accent)
          }
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))

        Section {
          HStack(spacing: 8) {
            TextField(participantPromptFR, text: $participant)
              .font(Typography.composer(typeface))
              .foregroundStyle(theme.ink)
              .keyboardType(network == .signal ? .default : .phonePad)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit { addParticipant() }
            Button("Ajouter", action: addParticipant)
              .disabled(participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          ForEach(participants, id: \.self) { item in
            HStack {
              Text(item).foregroundStyle(theme.ink)
              Spacer(minLength: 4)
              Button {
                participants.removeAll { $0 == item }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(theme.inkTertiary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Retirer \(item)")
            }
          }
        } header: {
          Text("Membres")
            .font(Typography.sidebarSection(typeface))
            .foregroundStyle(theme.inkTertiary)
        } footer: {
          Text("Le groupe est créé sur \(network.labelFR) : les autres membres le verront apparaître chez eux.")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))

        if let failure {
          Text(failure)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.accent)
            .listRowBackground(Color.clear)
        }
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Nouveau groupe")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Fermer") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if isCreating {
            ProgressView()
          } else {
            Button("Créer") { create() }
              .disabled(!canCreate)
          }
        }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
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

  /// Le pont crée le groupe ; le salon arrive par le `/sync` qui suit. On
  /// ferme la feuille — attendre devant serait mentir sur qui fait le travail.
  private func create() {
    guard canCreate else { return }
    isCreating = true
    failure = nil
    let target = network
    let title = trimmedName
    let people = participants
    Task {
      do {
        try await store.createGroup(network: target, name: title, identifiers: people)
        dismiss()
      } catch {
        failure = RelayStore.readable(error)
      }
      isCreating = false
    }
  }
}
