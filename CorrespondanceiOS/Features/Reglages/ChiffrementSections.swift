import CorrespondanceCore
import CorrespondanceMatrixClient
import CorrespondanceUI
import SwiftUI

/// Les deux écrans du chiffrement sur l'iPhone : la phrase de récupération, et
/// les appareils du compte.
///
/// Ils partagent **le même** `ModeleChiffrement` que le Mac, pour la raison qui
/// vaut ici plus qu'ailleurs : un iPhone est presque toujours le *second*
/// appareil, donc celui qui rencontre l'écran « Entrer la phrase ». Si les deux
/// plateformes décidaient chacune de leur côté quand le montrer, elles
/// finiraient par en montrer deux versions différentes du même compte.
///
/// Ce qui change, c'est la mise en forme : des `Section` de `List`, pas des
/// cartes ; une `NavigationLink` vers l'écran des appareils, parce qu'une liste
/// de sessions n'a pas sa place au milieu des réglages sur un écran de 6 pouces.
struct PhraseDeRecuperationSection: View {
  @Environment(ThemePreferences.self) private var themes
  let modele: ModeleChiffrement

  @State private var saisie = ""
  @State private var confirmeNotee = false

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    Section {
      switch modele.etape {
      case .inconnue:
        Text("Lecture de l'état…").font(Typography.meta(typeface)).foregroundStyle(theme.inkTertiary)

      case let .indisponible(raison):
        Text(raison).font(Typography.meta(typeface)).foregroundStyle(theme.inkTertiary)

      case .aProposer:
        Text(modele.etape.expliqueFR).font(Typography.meta(typeface)).foregroundStyle(theme.inkSecondary)
        Button("Créer la phrase") { modele.proposerUnePhrase() }
          .disabled(modele.occupe)

      case let .aNoter(phrase):
        Text(modele.etape.expliqueFR).font(Typography.meta(typeface)).foregroundStyle(theme.inkSecondary)
        MotsDeLaPhrase(phrase: phrase)
        Toggle("Je l'ai notée", isOn: $confirmeNotee)
        Button("Copier") { UIPasteboard.general.string = phrase }
        Button(modele.occupe ? "Création…" : "Continuer") {
          Task { await modele.confirmerLaPhrase() }
        }
        .disabled(!confirmeNotee || modele.occupe)

      case let .aEntrer(version):
        Text(modele.etape.expliqueFR).font(Typography.meta(typeface)).foregroundStyle(theme.inkSecondary)
        // Le clavier d'iOS met une majuscule au premier mot et propose des
        // corrections : les deux abîment une phrase de douze mots. On les
        // coupe, et la normalisation du modèle rattrape le reste.
        TextField("douze mots séparés par des espaces", text: $saisie, axis: .vertical)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button(modele.occupe ? "Restauration…" : "Entrer la phrase") {
          Task { await modele.entrerLaPhrase(saisie); saisie = "" }
        }
        .disabled(modele.occupe || saisie.isEmpty)
        Text("Sauvegarde \(version)").font(Typography.meta(typeface)).foregroundStyle(theme.inkTertiary)

      case let .enPlace(version, phraseConnue):
        Text(modele.etape.expliqueFR).font(Typography.meta(typeface)).foregroundStyle(theme.inkSecondary)
        if phraseConnue {
          Button(modele.phraseRevelee == nil ? "Revoir la phrase" : "Cacher la phrase") {
            if modele.phraseRevelee == nil { modele.revoirLaPhrase() } else { modele.cacherLaPhrase() }
          }
        }
        if let phrase = modele.phraseRevelee { MotsDeLaPhrase(phrase: phrase) }
        Button("Changer la phrase") {
          confirmeNotee = false
          modele.changerLaPhrase()
        }
        .disabled(modele.occupe)
        Text("Sauvegarde \(version)").font(Typography.meta(typeface)).foregroundStyle(theme.inkTertiary)
      }

      if let message = modele.message {
        Text(message).font(Typography.meta(typeface)).foregroundStyle(theme.inkSecondary)
      }
    } header: {
      Text("Phrase de récupération")
    } footer: {
      Text(
        "Douze mots qui ne quittent jamais cet appareil. "
          + "Sans eux, un nouvel appareil ne peut pas relire les anciens messages."
      )
      .font(Typography.meta(typeface))
    }
    .task { await modele.sonder() }
  }
}

/// Douze mots numérotés, en chasse fixe : fait pour être recopié sans se
/// tromper de ligne.
private struct MotsDeLaPhrase: View {
  @Environment(ThemePreferences.self) private var themes
  let phrase: String

  private var mots: [String] { phrase.split(separator: " ").map(String.init) }

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 8) {
      ForEach(Array(mots.enumerated()), id: \.offset) { index, mot in
        HStack(spacing: 4) {
          Text("\(index + 1).")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(themes.theme.inkTertiary)
          Text(mot)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(themes.theme.ink)
        }
      }
    }
    .textSelection(.enabled)
    .padding(.vertical, 6)
  }
}

/// La liste des appareils, derrière une `NavigationLink` : sur un téléphone,
/// quatre sessions au milieu des réglages noieraient le reste.
struct AppareilsSection: View {
  @Environment(ThemePreferences.self) private var themes
  let modele: ModeleChiffrement

  var body: some View {
    Section {
      NavigationLink {
        AppareilsListeView(modele: modele)
      } label: {
        HStack {
          Text("Appareils")
          Spacer()
          Text(modele.appareils.isEmpty ? "—" : "\(modele.appareils.count)")
            .foregroundStyle(themes.theme.inkTertiary)
        }
      }
    }
    .task { await modele.rafraichirLesAppareils() }
  }
}

struct AppareilsListeView: View {
  @Environment(ThemePreferences.self) private var themes
  let modele: ModeleChiffrement

  @State private var aDeconnecter: MatrixAppareilVu?
  @State private var motDePasse = ""
  @State private var motDePasseDemande = false

  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    List {
      Section {
        ForEach(modele.appareils) { appareil in
          VStack(alignment: .leading, spacing: 2) {
            Text(appareil.nom ?? appareil.deviceID).foregroundStyle(themes.theme.ink)
            Text(detail(appareil))
              .font(Typography.meta(typeface))
              .foregroundStyle(themes.theme.inkTertiary)
          }
          .swipeActions {
            if !appareil.estMoi {
              Button("Déconnecter", role: .destructive) {
                motDePasse = ""
                motDePasseDemande = false
                aDeconnecter = appareil
              }
            }
          }
        }
      } footer: {
        Text(
          "La dernière activité est notée toutes les dix minutes environ. "
            + "Un appareil actif peut donc sembler silencieux un moment."
        )
        .font(Typography.meta(typeface))
      }
    }
    .navigationTitle("Appareils")
    .refreshable { await modele.rafraichirLesAppareils() }
    .task { await modele.rafraichirLesAppareils() }
    .alert(
      "Déconnecter « \(aDeconnecter?.nom ?? aDeconnecter?.deviceID ?? "")" + " » ?",
      isPresented: Binding(get: { aDeconnecter != nil }, set: { if !$0 { aDeconnecter = nil } })
    ) {
      // Le champ n'apparaît qu'au second tour : le premier part sans mot de
      // passe, parce qu'un Relais qui ne le demande pas n'a pas à le recevoir.
      if motDePasseDemande {
        SecureField("Mot de passe du compte", text: $motDePasse)
      }
      Button("Annuler", role: .cancel) { aDeconnecter = nil }
      Button("Déconnecter", role: .destructive) {
        guard let appareil = aDeconnecter else { return }
        Task {
          let fait = await modele.deconnecter(
            appareil.deviceID, motDePasse: motDePasseDemande ? motDePasse : nil)
          if fait { aDeconnecter = nil } else { motDePasseDemande = true }
        }
      }
    } message: {
      Text(
        modele.message
          ?? "Cet appareil n’aura plus accès au compte. Tes messages restent lisibles sur les autres."
      )
    }
  }

  private func detail(_ appareil: MatrixAppareilVu) -> String {
    var morceaux = [appareil.etatFR]
    if appareil.nom != nil { morceaux.append(appareil.deviceID) }
    if let activite = appareil.activiteFR() { morceaux.append(activite) }
    return morceaux.joined(separator: " · ")
  }
}
