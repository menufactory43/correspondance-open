import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Le homeserver Matrix (Synapse sur le NUC, via Tailscale) : l'état du lien,
/// et le formulaire de session quand il n'y en a pas.
struct SettingsMatrixPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var homeserver = InboxStore.defaultHomeserver
  @State private var matrixUser = "meffysto"
  @State private var matrixPassword = ""
  @State private var isConnecting = false
  /// Le code que l'installeur du Relais a affiché — c'est le chemin normal.
  /// Le formulaire au-dessous reste pour qui préfère tout taper.
  @State private var codeAppairage = ""
  @State private var motsDeVerification: [String] = []
  /// Par où ce code se joint — montré **avant** de se connecter, pendant qu'on
  /// peut encore refuser.
  @State private var cheminDuCode: CheminDuRelais?
  @State private var erreurCode: String?
  /// Le modèle des deux écrans du chiffrement. Créé à la première connexion et
  /// jeté à la déconnexion : il porte l'identité du compte, et un modèle qui
  /// survivrait à un changement de compte montrerait la phrase de l'autre.
  @State private var chiffrement: ModeleChiffrement?

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    contenu
      .task(id: store.isMatrixConnected) { await preparerLeChiffrement() }
  }

  @ViewBuilder private var contenu: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Sur un jeu de données d'essai, on le dit avant tout le reste : personne
      // ne doit croire qu'il regarde ses vraies conversations.
      if let essai = CorrespondanceHome.name {
        SettingsCard(
          title: "Essai",
          footnote: "Tu regardes un jeu de données d’essai, pas tes vraies conversations. "
            + "Elles sont intactes et reviendront au prochain lancement normal."
        ) {
          SettingsRow(
            label: "Jeu de données",
            detail: "Correspondance-\(essai)",
            systemImage: "flask"
          ) { EmptyView() }
        }
      }

      SettingsCard(title: "État") {
        SettingsRow(
          label: "Connexion",
          detail: store.matrixStatusFR,
          systemImage: store.isMatrixConnected ? "checkmark.seal.fill" : "exclamationmark.triangle"
        ) {
          Button("Vérifier") {
            Task {
              await store.refreshMatrixStatus()
              // La machine crypto ne se branche qu'au premier `/sync` qui suit
              // la connexion : sondée avant, elle répond « pas encore
              // connecté ». Re-sonder doit donc resonder les deux, sinon
              // l'écran de la phrase reste en arrière d'un tour.
              await chiffrement?.sonder()
              await chiffrement?.rafraichirLesAppareils()
            }
          }
        }

        SettingsRow(
          label: "Chiffrement",
          detail: store.chiffrementFR,
          systemImage: "lock"
        ) {
          EmptyView()
        }

        if store.isMatrixConnected {
          SettingsRow(
            label: "Archives, épingles, brouillons",
            detail: relayStateDetail,
            systemImage: store.relayQueue.isEmpty ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath"
          ) {
            EmptyView()
          }
        }
      }

      if store.isMatrixConnected, let chiffrement {
        PhraseDeRecuperationCard(modele: chiffrement)
        AppareilsDuCompteCard(modele: chiffrement)
      }

      if store.isMatrixConnected {
        SettingsCard(title: "Session") {
          SettingsRow(
            label: "Fermer la session",
            detail: "WhatsApp, Instagram, Messenger et Signal disparaissent de l’inbox jusqu’à la prochaine connexion."
          ) {
            Button("Déconnecter") {
              Task { await store.disconnectMatrix() }
            }
          }

          SettingsRow(
            label: "Recharger depuis le Relais",
            detail: "Repart de zéro et recharge tout. Utile si l’inbox semble décalée."
          ) {
            Button("Recharger") {
              Task { await store.reloadFromRelay() }
            }
          }
        }
      } else {
        SettingsCard(
          title: "Connecter un Relais",
          footnote: "Colle ici le code affiché à la fin de l’installation du Relais. "
            + "Il contient un mot de passe, ne l’envoie à personne. Il expire au bout de quinze minutes."
        ) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("correspondance://relais/…", text: $codeAppairage)
              .textFieldStyle(.roundedBorder)
              .onSubmit { appairer() }

            if !motsDeVerification.isEmpty {
              Text("Vérification : \(motsDeVerification.joined(separator: " "))")
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkSecondary)
              Text("Ces six mots doivent être les mêmes que ceux affichés par l’installeur.")
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkTertiary)
            }
            if let cheminDuCode {
              Text("Chemin : \(cheminDuCode.titreFR)")
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkSecondary)
              Text(cheminDuCode.detailFR)
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let erreurCode {
              Text(erreurCode)
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkSecondary)
            }
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)

          HStack {
            Spacer()
            Button(isConnecting ? "Connexion…" : "Connecter") { appairer() }
              .keyboardShortcut(.defaultAction)
              .disabled(isConnecting || codeAppairage.isEmpty)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
        }

        SettingsCard(title: "Ou avec un identifiant") {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Adresse du Relais", text: $homeserver)
            TextField("Identifiant", text: $matrixUser)
            SecureField("Mot de passe", text: $matrixPassword)
          }
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)

          HStack {
            Spacer()
            Button(isConnecting ? "Connexion…" : "Connexion") {
              connect()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isConnecting || matrixUser.isEmpty || matrixPassword.isEmpty)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
        }
      }
    }
  }

  /// Le modèle des écrans du chiffrement suit la session : il naît avec elle et
  /// meurt avec elle. `MatrixCredentialStore.load()` plutôt qu'un identifiant
  /// gardé en vue : c'est la même source que le client, donc les deux ne peuvent
  /// pas diverger.
  private func preparerLeChiffrement() async {
    guard store.isMatrixConnected, let compte = MatrixCredentialStore.load()?.userID else {
      chiffrement = nil
      return
    }
    if chiffrement == nil {
      chiffrement = ModeleChiffrement(
        compte: compte,
        service: ChiffrementParLeRelais(store.matrix),
        magasin: MagasinDePhraseAuTrousseau()
      )
    }
    await chiffrement?.sonder()
  }

  /// Archives, épingles, sourdines et brouillons vivent dans le Relais (ADR 0001).
  /// Rien à régler ici : juste de quoi voir qu'une écriture attend son tour.
  private var relayStateDetail: String {
    let pending = store.relayQueue.count
    guard pending > 0 else { return "À jour." }
    return pending == 1 ? "1 modification en attente." : "\(pending) modifications en attente."
  }

  /// Lit le code, montre les six mots, puis se connecte. On affiche
  /// l'empreinte **avant** de se connecter : c'est là qu'elle sert.
  private func appairer() {
    erreurCode = nil
    guard let code = RelayPairingCode(encoded: codeAppairage) else {
      motsDeVerification = []
      cheminDuCode = nil
      erreurCode = "Ce code n’est pas lisible. Recopie-le en entier."
      return
    }
    guard !code.isExpired() else {
      motsDeVerification = []
      cheminDuCode = nil
      erreurCode = "Ce code a expiré. Demande-en un nouveau sur le Relais."
      return
    }
    motsDeVerification = code.fingerprintWords()
    cheminDuCode = code.chemin
    isConnecting = true
    Task {
      erreurCode = await store.connecterParLeCode(code)
      codeAppairage = ""
      isConnecting = false
    }
  }

  private func connect() {
    isConnecting = true
    Task {
      await store.connectMatrix(
        homeserver: homeserver,
        user: matrixUser,
        password: matrixPassword
      )
      matrixPassword = ""
      isConnecting = false
    }
  }
}
