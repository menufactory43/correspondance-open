import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Les Réglages de l'iPhone — quatre sections, et rien de plus.
///
/// Ce qu'on N'Y trouve pas est aussi net que ce qu'on y trouve : aucune gestion
/// de pont. Relier un compte WhatsApp demande de scanner un QR, de lire les
/// réponses d'un bot, de recoller des cookies — un travail d'établi, qui se
/// fait sur le Mac (décision 4). L'iPhone lit la liste des ponts actifs et le
/// dit en une ligne.
struct SettingsView: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(PushRegistration.self) private var push
  @Environment(\.dismiss) private var dismiss

  @State private var credentials: MatrixCredentials?
  @State private var isSigningOut = false
  @State private var confirmsSignOut = false

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    NavigationStack {
      List {
        relaySection
        bridgesSection
        themeSection
        sendingSection
        agentSection
        notificationsSection
        signOutSection
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Réglages")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .task {
      credentials = MatrixCredentialStore.load()
      await push.refreshAuthorization()
    }
    .confirmationDialog(
      "Se déconnecter du Relais ?",
      isPresented: $confirmsSignOut,
      titleVisibility: .visible
    ) {
      Button("Se déconnecter", role: .destructive) { signOut() }
      Button("Annuler", role: .cancel) {}
    } message: {
      Text("Les conversations restent sur le Relais. Cet iPhone oublie sa session et cesse d'être réveillé.")
    }
  }

  // MARK: - Relais

  private var relaySection: some View {
    Section {
      row("Adresse", credentials?.homeserver.absoluteString ?? store.rememberedHomeserver)
      row("Identifiant", credentials?.userID ?? "—")
      row("Session", sessionLabel)
      // La même phrase que sur le Mac, au mot près : c'est le même état, il n'a
      // pas à se raconter de deux façons.
      row("État de conversation", relayStateLabel)
    } header: {
      Text("Relais")
    } footer: {
      if let error = store.syncError {
        Text(error).font(Typography.meta(typeface)).foregroundStyle(theme.accent)
      } else {
        Text("Le Relais se joint par Tailscale. Son adresse est une configuration, jamais une valeur en dur.")
          .font(Typography.meta(typeface))
      }
    }
  }

  private var sessionLabel: String {
    switch store.session {
    case .connected: store.syncError == nil ? "Connectée" : "Connectée, sync en échec"
    case .connecting: "Connexion…"
    case .disconnected: "Déconnectée"
    case .unknown: "Inconnue"
    }
  }

  private var relayStateLabel: String {
    let pending = store.relayQueue.count
    guard pending > 0 else { return "Synchronisé" }
    return "Synchronisé · \(pending) en attente"
  }

  // MARK: - Ponts

  private var bridgesSection: some View {
    Section {
      if store.networksInUse.isEmpty {
        Text("Aucun pont ne parle encore.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      } else {
        ForEach(store.networksInUse) { network in
          HStack {
            Label(network.labelFR, systemImage: network.systemImage)
              .foregroundStyle(theme.ink)
            Spacer()
            Text(countLabel(network))
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkTertiary)
          }
        }
      }
    } header: {
      Text("Comptes liés")
    } footer: {
      Text("Les comptes liés se connectent depuis le Mac — un QR à scanner, un bot à écouter. L'iPhone lit ce que le Relais raconte.")
        .font(Typography.meta(typeface))
    }
  }

  private func countLabel(_ network: MessageNetwork) -> String {
    let count = store.conversations.count { $0.network == network }
    return count == 1 ? "1 conversation" : "\(count) conversations"
  }

  // MARK: - Thème

  private var themeSection: some View {
    @Bindable var themes = themes
    return Section {
      Picker("Thème", selection: $themes.themeID) {
        ForEach(WritingThemeID.allCases) { id in
          Label(id.labelFR, systemImage: id.systemImage).tag(id)
        }
      }
      Picker("Typographie", selection: $themes.typeface) {
        ForEach(WritingTypeface.allCases) { face in
          Text(face.labelFR).tag(face)
        }
      }
    } header: {
      Text("Écriture")
    } footer: {
      Text("Les six thèmes du Mac, et les mêmes fontes : les deux appareils écrivent de la même main.")
        .font(Typography.meta(typeface))
    }
  }

  // MARK: - Envoi

  /// Le délai de grâce : le temps pendant lequel la bulle est là mais rien
  /// n'a encore quitté l'appareil.
  private var sendingSection: some View {
    Section {
      Picker("Annuler l'envoi", selection: Binding(
        get: { store.undoSendDelay },
        set: { store.undoSendDelay = $0 }
      )) {
        ForEach(UndoSendDelay.allCases) { choice in
          Text(choice.labelFR).tag(choice)
        }
      }
    } header: {
      Text("Envoi")
    } footer: {
      Text("La bulle paraît tout de suite, mais le message ne part qu'au bout de ce délai : d'ici là, « Annuler » sous la bulle rend le texte au composer.")
        .font(Typography.meta(typeface))
    }
  }

  // MARK: - Agent

  /// « cc » ne tourne pas ici : c'est un processus à part, sur le Relais. Ce
  /// choix part dans l'account data Matrix globale, et l'agent l'y relit — le
  /// Mac et l'iPhone écrivent donc le même réglage, au même endroit.
  private var agentSection: some View {
    Section {
      Picker("Dans les groupes", selection: Binding(
        get: { store.agentDefaultMode },
        set: { store.setAgentDefaultMode($0) }
      )) {
        Text("Brouillon à valider").tag(AgentSettings.Mode.draft)
        Text("À voix haute").tag(AgentSettings.Mode.direct)
      }
      Text(store.agentDefaultMode.subtitleFR)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
    } header: {
      Text("Agent")
    } footer: {
      Text("En tête-à-tête avec toi, cc répond toujours à voix haute. Le réglage part sur le Relais ; cc le relit à sa prochaine synchronisation.")
        .font(Typography.meta(typeface))
    }
  }

  // MARK: - Notifications

  private var notificationsSection: some View {
    Section {
      row("Autorisation", push.authorizationLabelFR)
      row("Inscription au Relais", push.isRegistered ? "Faite" : "Pas encore")
      row("Passerelle", PushRegistration.sygnalURL.absoluteString)
      if push.authorization == .notDetermined {
        Button("Autoriser les notifications") {
          Task { await push.requestAuthorizationIfNeeded() }
        }
      } else {
        Button("Ouvrir les Réglages du système") {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          UIApplication.shared.open(url)
        }
      }
      // Le jeton tourne, et la passerelle peut avoir été installée après coup :
      // redéclarer est le seul geste que l'iPhone puisse tenter tout seul.
      Button("Redéclarer cet appareil au Relais") {
        Task { await push.declareToRelay() }
      }
      .disabled(!push.isAuthorizedForPush)
    } header: {
      Text("Notifications")
    } footer: {
      if let error = push.lastError {
        Text(error).font(Typography.meta(typeface)).foregroundStyle(theme.accent)
      } else {
        Text("""
          Une conversation en muet ne notifie pas : le Relais ne l'envoie même pas.
          Le réveil d'un iPhone endormi passe par le Relais et sa passerelle (Sygnal) :           sans elle, cet iPhone n'est notifié que pendant que l'app tourne.
          """)
          .font(Typography.meta(typeface))
      }
    }
  }

  // MARK: - Déconnexion

  private var signOutSection: some View {
    Section {
      Button {
        Task { await store.reloadFromRelay() }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Recharger depuis le Relais")
          Text("Vide la base locale et refait une synchronisation complète.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(store.isDemo || store.session != .connected)

      Button(role: .destructive) {
        confirmsSignOut = true
      } label: {
        HStack {
          Text("Se déconnecter")
          Spacer()
          if isSigningOut { ProgressView() }
        }
      }
      .disabled(isSigningOut || store.isDemo)
    }
  }

  private func signOut() {
    isSigningOut = true
    Task {
      // L'ordre compte : le pusher part tant que le jeton d'accès vaut encore.
      await store.signOut(push: push)
      isSigningOut = false
      dismiss()
    }
  }

  // MARK: - Habillage

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(theme.ink)
      Spacer(minLength: Spacing.sm)
      Text(value.isEmpty ? "—" : value)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }
}
