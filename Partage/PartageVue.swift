import CorrespondanceCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// La feuille de partage : la même sur iPhone et sur Mac.
///
/// Une liste de personnes, une recherche, un mot à ajouter, Envoyer. Pas de
/// réseau à choisir : la personne porte le sien, et la pastille le rappelle.
struct PartageVue: View {
  @Bindable var modele: PartageModele
  let annuler: () -> Void
  let terminer: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      entete
      Divider()
      switch modele.etat {
      case .lecture:
        Spacer()
        ProgressView("Lecture…")
        Spacer()
      case .echec(let message):
        Spacer()
        Label(message, systemImage: "exclamationmark.triangle")
          .multilineTextAlignment(.center)
          .padding()
        Spacer()
      case .fini(let message):
        Spacer()
        Label(message, systemImage: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .padding()
        Spacer()
      case .pret, .envoi:
        liste
        Divider()
        pied
      }
    }
    #if os(macOS)
      .frame(width: 440, height: 560)
    #endif
  }

  private var entete: some View {
    HStack {
      Button("Annuler", action: annuler)
        .keyboardShortcut(.cancelAction)
      Spacer()
      VStack(spacing: 2) {
        Text("Correspondance").font(.headline)
        if !modele.resume.isEmpty {
          Text(modele.resume).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Envoyer") { Task { if await modele.envoyer() { terminer() } } }
        .keyboardShortcut(.defaultAction)
        .fontWeight(.semibold)
        .disabled(!modele.peutEnvoyer)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var liste: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("À qui ?", text: $modele.requete)
          .textFieldStyle(.plain)
          // Retour dans la recherche : le premier résultat est le bon, en général.
          .onSubmit { if let premier = modele.visibles.first { modele.choisi = premier } }
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }
      .padding(8)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
      .padding(.horizontal)
      .padding(.vertical, 8)
      contenuDeLaListe
    }
  }

  /// Des boutons plutôt qu'une `List(selection:)` : hébergée dans la feuille
  /// de partage (une vue distante), la liste ne rendait pas le clic sur Mac.
  private var contenuDeLaListe: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if modele.visibles.isEmpty {
          Text("Personne ne s'appelle « \(modele.requete) »")
            .foregroundStyle(.secondary)
            .padding()
        }
        ForEach(modele.visibles) { row in
          Button { modele.choisi = row } label: { ligne(row) }
            .buttonStyle(.plain)
          Divider().padding(.leading, 68)
        }
      }
    }
    .disabled(modele.etat == .envoi)
    .overlay {
      if modele.etat == .envoi {
        ProgressView("Envoi…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  private func ligne(_ row: Partage.Destinataire) -> some View {
    HStack(spacing: 12) {
      PartageAvatar(titre: row.title, network: row.network, isGroup: row.isGroup, data: modele.avatar(row))
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title).lineLimit(1)
        Text(row.network.labelFR).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if modele.choisi == row {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(modele.choisi == row ? Color.accentColor.opacity(0.08) : .clear)
  }

  private var pied: some View {
    HStack {
      TextField(
        modele.contenu.fichiers.isEmpty ? "Un message" : "Ajouter un mot",
        text: $modele.mot,
        axis: .vertical
      )
      .lineLimit(1...4)
      .textFieldStyle(.roundedBorder)
      .onSubmit { Task { if await modele.envoyer() { terminer() } } }
    }
    .padding()
  }
}

/// Le rond de la personne : sa photo si l'app l'avait, ses initiales sinon,
/// et la pastille du réseau en bas à droite.
struct PartageAvatar: View {
  let titre: String
  let network: MessageNetwork
  let isGroup: Bool
  let data: Data?

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if let data, let image = PartageImage(data: data) {
          image.resizable().scaledToFill()
        } else {
          Circle().fill(Color.accentColor.opacity(0.18))
            .overlay {
              if isGroup {
                Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary)
              } else {
                Text(initiales).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
              }
            }
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(Circle())
      Image(systemName: network.systemImage)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .padding(3)
        .background(Circle().fill(Color.accentColor))
        .overlay(Circle().stroke(.background, lineWidth: 1.5))
        .offset(x: 3, y: 3)
    }
    .accessibilityLabel("\(titre), \(network.labelFR)")
  }

  private var initiales: String {
    let mots = titre.split(whereSeparator: \.isWhitespace).prefix(2)
    let lettres = mots.compactMap { $0.first }.map { String($0).uppercased() }
    return lettres.isEmpty ? "?" : lettres.joined()
  }
}

/// `Image` depuis des octets, sur les deux plateformes.
private func PartageImage(data: Data) -> Image? {
  #if canImport(UIKit)
    UIImage(data: data).map { Image(uiImage: $0) }
  #else
    NSImage(data: data).map { Image(nsImage: $0) }
  #endif
}
