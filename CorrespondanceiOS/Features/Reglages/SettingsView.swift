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
  /// Le modèle des deux écrans du chiffrement — le même qu'au Mac. Il naît
  /// avec la session et meurt avec elle : un modèle qui survivrait à un
  /// changement de compte montrerait la phrase de l'autre.
  @State private var chiffrement: ModeleChiffrement?
  @State private var isSigningOut = false
  @State private var confirmsSignOut = false

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    NavigationStack {
      List {
        relaySection
        if let chiffrement {
          PhraseDeRecuperationSection(modele: chiffrement)
          AppareilsSection(modele: chiffrement)
        }
        bridgesSection
        themeSection
        sendingSection
        incognitoSection
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
      if let compte = credentials?.userID, chiffrement == nil {
        chiffrement = ModeleChiffrement(
          compte: compte,
          service: ChiffrementParLeRelais(store.matrix),
          magasin: MagasinDePhraseAuTrousseau()
        )
      }
    }
    .confirmationDialog(
      "Se déconnecter du Relais ?",
      isPresented: $confirmsSignOut,
      titleVisibility: .visible
    ) {
      Button("Se déconnecter", role: .destructive) { signOut() }
      Button("Annuler", role: .cancel) {}
    } message: {
      Text("Tes conversations restent sur le Relais. Cet iPhone ne recevra plus de notifications.")
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
      row("Archives, épingles, brouillons", relayStateLabel)
    } header: {
      Text("Relais")
    } footer: {
      if let error = store.syncError {
        Text(error).font(Typography.meta(typeface)).foregroundStyle(theme.accent)
      } else {
        Text("Ton serveur, celui qui porte tes conversations. Il faut être sur son réseau pour l’atteindre.")
          .font(Typography.meta(typeface))
      }
    }
  }

  private var sessionLabel: String {
    switch store.session {
    case .connected: store.syncError == nil ? "Connectée" : "Connectée, mise à jour en échec"
    case .connecting: "Connexion…"
    case .disconnected: "Déconnectée"
    case .unknown: "Inconnue"
    }
  }

  private var relayStateLabel: String {
    let pending = store.relayQueue.count
    guard pending > 0 else { return "À jour" }
    return pending == 1 ? "1 modification en attente" : "\(pending) modifications en attente"
  }

  // MARK: - Ponts

  private var bridgesSection: some View {
    Section {
      if store.networksInUse.isEmpty {
        Text("Aucun compte lié pour l’instant.")
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
      Text("Les comptes se lient depuis le Mac. L’iPhone les retrouve tout seul.")
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
      Text("Les mêmes thèmes et polices que sur le Mac.")
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
      Text("La bulle s’affiche tout de suite, mais le message part seulement après ce délai. D’ici là, « Annuler » le ramène dans le champ de saisie.")
        .font(Typography.meta(typeface))
    }
  }

  // MARK: - Incognito

  /// Lire sans le dire : aucun accusé de lecture, le compteur reste.
  private var incognitoSection: some View {
    Section {
      Toggle("Mode incognito", isOn: Binding(
        get: { store.isIncognito },
        set: { store.isIncognito = $0 }
      ))
    } header: {
      Text("Lecture")
    } footer: {
      Text("Ouvrir une conversation n’envoie pas d’accusé de lecture, et le compteur de non-lus reste. Répondre ou « Marquer comme lu » le remet à zéro.")
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
      Text("En tête-à-tête avec toi, cc répond toujours directement. Le réglage est pris en compte à sa prochaine synchronisation.")
        .font(Typography.meta(typeface))
    }
  }

  // MARK: - Notifications

  private var notificationsSection: some View {
    Section {
      row("Autorisation", push.authorizationLabelFR)
      row("Enregistré sur le Relais", push.isRegistered ? "Oui" : "Pas encore")
      // La passerelle est publique et partagée : la montrer, c'est dire où part
      // le réveil. Et l'app_id avec, parce que c'est lui qui choisit
      // l'environnement APNs — le seul réglage dont l'erreur est silencieuse.
      row("Passerelle", PushRegistration.sygnalURL.absoluteString)
      row("Environnement", PushRegistration.pusherAppID)
      if push.authorization == .notDetermined {
        Button("Autoriser les notifications") {
          Task { await push.requestAuthorizationIfNeeded() }
        }
      } else {
        Button("Ouvrir les Réglages") {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          UIApplication.shared.open(url)
        }
      }
      // Le jeton tourne, et la passerelle peut avoir été installée après coup :
      // redéclarer est le seul geste que l'iPhone puisse tenter tout seul.
      Button("Réenregistrer cet iPhone") {
        Task { await push.declareToRelay() }
      }
      .disabled(!push.isAuthorizedForPush)
    } header: {
      Text("Notifications")
    } footer: {
      if let error = push.lastError {
        Text(error).font(Typography.meta(typeface)).foregroundStyle(theme.accent)
      } else {
        Text("Une conversation en muet ne notifie pas. Si les notifications n’arrivent plus quand l’app est fermée, réenregistre cet iPhone.")
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
          Text("Repart de zéro et recharge tout.")
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
