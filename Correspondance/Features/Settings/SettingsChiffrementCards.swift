import SwiftUI
import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceUI

/// Les deux écrans du chiffrement, dans Réglages › Matrix : la phrase de
/// récupération, et les appareils du compte.
///
/// Ils ne décident rien : `ModeleChiffrement` (dans `CorrespondanceCore`)
/// porte les états et les transitions, et il est éprouvé sans Relais. Ce
/// fichier n'est que de la mise en page — c'est délibéré, parce que la seule
/// question difficile de ces écrans (*quoi montrer à la première connexion d'un
/// appareil ?*) est une question de faits distants, pas de SwiftUI.

// MARK: - La phrase de récupération

struct PhraseDeRecuperationCard: View {
  @Environment(ThemePreferences.self) private var themes
  let modele: ModeleChiffrement

  @State private var saisie = ""
  @State private var confirmeNotee = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    SettingsCard(title: "Phrase de récupération", footnote: pied) {
      switch modele.etape {
      case .inconnue:
        SettingsRow(label: "Phrase de récupération", detail: "Lecture de l'état…") { EmptyView() }

      case let .indisponible(raison):
        SettingsRow(label: "Phrase de récupération", detail: raison, systemImage: "key.slash") {
          EmptyView()
        }

      case .aProposer:
        SettingsRow(
          label: modele.etape.titreFR,
          detail: modele.etape.expliqueFR,
          systemImage: "key.horizontal"
        ) {
          Button("Créer la phrase") { modele.proposerUnePhrase() }
            .disabled(modele.occupe)
        }

      case let .aNoter(phrase):
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(modele.etape.expliqueFR)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
          MotsDeLaPhrase(phrase: phrase)
          Toggle("Je l'ai notée", isOn: $confirmeNotee)
            .toggleStyle(.checkbox)
          HStack {
            Button("Copier") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(phrase, forType: .string)
            }
            Spacer()
            // Le bouton reste éteint tant que la case n'est pas cochée : c'est
            // la seule protection possible contre une sauvegarde que personne
            // ne pourra jamais rouvrir.
            Button(modele.occupe ? "Création…" : "Continuer") {
              Task { await modele.confirmerLaPhrase() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!confirmeNotee || modele.occupe)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)

      case let .aEntrer(version):
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(modele.etape.expliqueFR)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
          TextField("douze mots séparés par des espaces", text: $saisie)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await modele.entrerLaPhrase(saisie) } }
          HStack {
            Text("Sauvegarde \(version)")
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
            Spacer()
            Button(modele.occupe ? "Restauration…" : "Entrer la phrase") {
              Task { await modele.entrerLaPhrase(saisie); saisie = "" }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(modele.occupe || saisie.isEmpty)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)

      case let .enPlace(version, phraseConnue):
        SettingsRow(
          label: "Sauvegarde des clés",
          detail: modele.etape.expliqueFR,
          systemImage: "checkmark.seal"
        ) {
          HStack {
            if phraseConnue {
              Button(modele.phraseRevelee == nil ? "Revoir" : "Cacher") {
                if modele.phraseRevelee == nil { modele.revoirLaPhrase() } else { modele.cacherLaPhrase() }
              }
            }
            Button("Changer la phrase") {
              confirmeNotee = false
              modele.changerLaPhrase()
            }
            .disabled(modele.occupe)
          }
          .accessibilityLabel("Sauvegarde \(version)")
        }
        if let phrase = modele.phraseRevelee {
          MotsDeLaPhrase(phrase: phrase)
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, Spacing.xs)
        }
      }

      if let message = modele.message {
        Text(message)
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
      }
    }
    .task { await modele.sonder() }
  }

  private var pied: String? {
    switch modele.etape {
    case .aNoter:
      "Ces mots restent sur ce Mac. Personne d’autre que toi ne peut les retrouver, pas même le Relais."
    case .enPlace:
      "La phrase est gardée dans le trousseau de ce Mac. Elle n’en est jamais sortie."
    default:
      nil
    }
  }
}

/// Douze mots, numérotés, en chasse fixe : c'est fait pour être recopié à la
/// main sans se tromper de ligne.
private struct MotsDeLaPhrase: View {
  @Environment(ThemePreferences.self) private var themes
  let phrase: String

  private var mots: [String] { phrase.split(separator: " ").map(String.init) }

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 6) {
      ForEach(Array(mots.enumerated()), id: \.offset) { index, mot in
        HStack(spacing: 4) {
          Text("\(index + 1).")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(themes.theme.inkTertiary)
          Text(mot)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(themes.theme.ink)
        }
      }
    }
    .textSelection(.enabled)
    .padding(Spacing.sm)
    .background(themes.theme.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(themes.theme.separator, lineWidth: 1)
    }
  }
}

// MARK: - Les appareils du compte

struct AppareilsDuCompteCard: View {
  @Environment(ThemePreferences.self) private var themes
  let modele: ModeleChiffrement

  @State private var aDeconnecter: MatrixAppareilVu?
  @State private var motDePasse = ""

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    SettingsCard(
      title: "Appareils",
      footnote: "La dernière activité est notée toutes les dix minutes environ. "
        + "Un appareil actif peut donc sembler silencieux un moment."
    ) {
      if modele.appareils.isEmpty {
        SettingsRow(
          label: "Aucun appareil listé",
          detail: modele.occupe ? "Lecture…" : "Le Relais n’a rien renvoyé.",
          systemImage: "laptopcomputer"
        ) {
          Button("Recharger") { Task { await modele.rafraichirLesAppareils() } }
        }
      }
      ForEach(modele.appareils) { appareil in
        SettingsRow(
          label: appareil.nom ?? appareil.deviceID,
          detail: detail(appareil),
          systemImage: icone(appareil)
        ) {
          if !appareil.estMoi {
            Button("Déconnecter") {
              motDePasse = ""
              aDeconnecter = appareil
            }
            .disabled(modele.occupe)
          }
        }
      }
    }
    .task { await modele.rafraichirLesAppareils() }
    .sheet(item: $aDeconnecter) { appareil in
      FeuilleDeDeconnexion(appareil: appareil, modele: modele, motDePasse: $motDePasse) {
        aDeconnecter = nil
      }
    }
  }

  private func detail(_ appareil: MatrixAppareilVu) -> String {
    var morceaux = [appareil.etatFR]
    if appareil.nom != nil { morceaux.append(appareil.deviceID) }
    if let activite = appareil.activiteFR() { morceaux.append(activite) }
    if let ip = appareil.derniereAdresse { morceaux.append(ip) }
    return morceaux.joined(separator: " · ")
  }

  private func icone(_ appareil: MatrixAppareilVu) -> String {
    if appareil.verifieParSignature { return "checkmark.shield" }
    if appareil.etatCryptoInconnu { return "questionmark.circle" }
    return "exclamationmark.shield"
  }
}

/// Le Relais demande presque toujours le mot de passe pour retirer un appareil.
/// La feuille tente d'abord **sans** — un serveur qui ne le demande pas ne doit
/// pas le recevoir — et n'affiche le champ que s'il le réclame.
private struct FeuilleDeDeconnexion: View {
  let appareil: MatrixAppareilVu
  let modele: ModeleChiffrement
  @Binding var motDePasse: String
  let fermer: () -> Void

  @State private var motDePasseDemande = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Déconnecter « \(appareil.nom ?? appareil.deviceID) » ?")
        .font(.headline)
      Text(
        "Cet appareil n’aura plus accès au compte. Tes messages restent lisibles sur les autres."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if motDePasseDemande {
        SecureField("Mot de passe du compte", text: $motDePasse)
          .textFieldStyle(.roundedBorder)
      }
      if let message = modele.message {
        Text(message).font(.callout).foregroundStyle(.secondary)
      }

      HStack {
        Button("Annuler") { fermer() }
        Spacer()
        Button(modele.occupe ? "…" : "Déconnecter") {
          Task {
            let fait = await modele.deconnecter(
              appareil.deviceID, motDePasse: motDePasseDemande ? motDePasse : nil)
            if fait { fermer() } else { motDePasseDemande = true }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(modele.occupe || (motDePasseDemande && motDePasse.isEmpty))
      }
    }
    .padding(Spacing.lg)
    .frame(width: 420)
  }
}
