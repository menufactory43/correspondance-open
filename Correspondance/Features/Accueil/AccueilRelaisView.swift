import AppKit
import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// L'écran qui remplace l'inbox vide tant qu'il n'y a pas de Relais.
///
/// Une inbox vide ne dit rien : elle ressemble à une app cassée, ou à une app
/// dont on n'a rien à attendre. Ce qu'il manque, c'est un Relais — et il n'y a
/// que **deux** façons d'en avoir un, alors il y a deux cartes.
///
/// Ce qu'on ne demande pas : où héberger (il n'y a pas de troisième carte,
/// nous n'hébergeons rien) et s'il faut chiffrer (c'est d'office depuis la
/// phase 5 ; poser la question laisserait croire qu'on peut répondre non).
struct AccueilRelaisView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var installateur = RelaisInstallateur()
  @State private var codeAppairage = ""
  @State private var motsDeVerification: [String] = []
  @State private var erreurCode: String?
  @State private var copie = false

  private var theme: WritingTheme { themes.theme }

  /// Un Relais posé par l'installeur, marque sur le disque à l'appui.
  private var relaisPose: Bool {
    if case .fini = installateur.phase { return true }
    return RelaisInstallateur.poseSurCeMac
  }

  /// La commande à coller sur une machine à soi. Le même « pas de curl | sh »
  /// que l'installeur de l'agent : un domaine absent donne un script vide, et
  /// `sh` d'un script vide sort en 0 — « installé » sans rien faire.
  private var commande: String {
    "curl -fsSLO \(RelaisInstallateur.releases)/relais-install.sh && bash relais-install.sh"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        entete
        carteCeMac
        carteMachineAMoi
      }
      .frame(maxWidth: 620, alignment: .leading)
      .padding(Spacing.xl)
      .frame(maxWidth: .infinity)
    }
    .background(theme.paper)
  }

  private var entete: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Il manque un Relais")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(theme.ink)
      Text(
        "Le Relais est la machine qui tient tes conversations : WhatsApp, Signal, Instagram, "
          + "Messenger, et tes notes. Il est à toi, il ne sort pas de chez toi, et tout ce "
          + "qui y passe est chiffré. Il n'y a que deux endroits où le poser."
      )
      .font(.body)
      .foregroundStyle(theme.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Sur ce Mac

  private var carteCeMac: some View {
    SettingsCard(
      title: "Sur ce Mac",
      footnote: "Tout marche tant que ce Mac est allumé. Ton iPhone ne recevra rien quand il dort."
    ) {
      SettingsRow(
        label: "Installer ici",
        detail: detailCeMac,
        systemImage: "desktopcomputer"
      ) {
        switch installateur.phase {
        case .repos:
          Button("Installer ici") { Task { await installer() } }
        case .enCours:
          ProgressView().controlSize(.small)
        case .echec:
          Button("Réessayer") { Task { await installer() } }
        case .fini:
          Image(systemName: "checkmark.circle.fill")
        }
      }

      if !installateur.etapes.isEmpty {
        SettingsDivider()
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(installateur.etapes, id: \.etape) { etape in
            ligneEtape(etape)
          }
          if !installateur.mots.isEmpty {
            Text("Vérification : \(installateur.mots.joined(separator: " "))")
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              .padding(.top, Spacing.xxs)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
      }

      if relaisPose {
        SettingsDivider()
        SettingsRow(
          label: "Tout retirer",
          detail: "Arrête les services, efface le dossier du Relais, et ne touche à rien d'autre.",
          systemImage: "trash"
        ) {
          Button("Tout retirer", role: .destructive) { Task { await installateur.retirer() } }
        }
      }
    }
  }

  private var detailCeMac: String {
    switch installateur.phase {
    case .repos:
      "Une minute, aucune question : l'app pose le Relais et les quatre réseaux, "
        + "puis se connecte elle-même. Rien à recopier."
    case .enCours: "installation en cours…"
    case .echec(let raison): raison
    case .fini: "le Relais tourne sur ce Mac, et l'app y est connectée."
    }
  }

  @ViewBuilder
  private func ligneEtape(_ etape: RelaisEtape) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
      Image(systemName: symbole(etape.etat))
        .font(.system(size: 11))
        .foregroundStyle(etape.etat == .erreur ? theme.inkSecondary : theme.accent)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(etape.libelleFR)
          .font(.caption)
          .foregroundStyle(theme.ink)
        if !etape.detail.isEmpty {
          Text(etape.detail)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private func symbole(_ etat: RelaisEtape.Etat) -> String {
    switch etat {
    case .debut: "circle.dotted"
    case .ok: "checkmark.circle.fill"
    case .erreur: "exclamationmark.triangle"
    }
  }

  /// L'app colle le code **elle-même**. C'est tout l'objet de la carte : le
  /// chemin est le même que celui du champ des réglages
  /// (`RelayPairingCode` → `connectMatrix`), sans le copier-coller.
  private func installer() async {
    await installateur.installer { code in
      motsDeVerification = code.fingerprintWords()
      await store.connectMatrix(
        homeserver: code.homeserver.absoluteString,
        user: code.userID,
        password: code.password
      )
    }
  }

  // MARK: - Sur une machine à moi

  private var carteMachineAMoi: some View {
    SettingsCard(
      title: "Sur une machine à moi",
      footnote: "La commande contient de quoi installer, pas un secret : c'est le code "
        + "d'appairage qu'elle affiche à la fin qui en porte un. Il périme en quinze minutes."
    ) {
      SettingsRow(
        label: "Allumée en permanence, tout marche partout. Il faut Tailscale sur l'iPhone.",
        detail: commande,
        systemImage: "server.rack"
      ) {
        Button(copie ? "Copié" : "Copier") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(commande, forType: .string)
          copie = true
        }
      }

      SettingsRow(
        label: "Un NUC chez toi est plus sûr qu'un serveur loué : l'hébergeur a l'accès physique.",
        systemImage: "house"
      )

      SettingsDivider()

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Colle ici le code que la commande a affiché")
          .font(.caption)
          .foregroundStyle(theme.inkSecondary)
        TextField("correspondance://relais/…", text: $codeAppairage)
          .textFieldStyle(.roundedBorder)
          .onSubmit { appairer() }

        if !motsDeVerification.isEmpty {
          Text("Vérification : \(motsDeVerification.joined(separator: " "))")
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
          Text("Ces six mots doivent être ceux que l'installeur a affichés.")
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
        }
        if let erreurCode {
          Text(erreurCode)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
        }

        HStack {
          Spacer()
          Button("Connecter") { appairer() }
            .keyboardShortcut(.defaultAction)
            .disabled(codeAppairage.isEmpty)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
    }
  }

  /// Le même code que `SettingsMatrixPane.appairer()` : les six mots avant la
  /// connexion, parce que c'est là qu'ils servent.
  private func appairer() {
    erreurCode = nil
    guard let code = RelayPairingCode(encoded: codeAppairage) else {
      motsDeVerification = []
      erreurCode = "ce code n'est pas lisible — recopie-le en entier"
      return
    }
    guard !code.isExpired() else {
      motsDeVerification = []
      erreurCode = "ce code a expiré — relance l'installeur sur la machine du Relais"
      return
    }
    motsDeVerification = code.fingerprintWords()
    Task {
      await store.connectMatrix(
        homeserver: code.homeserver.absoluteString,
        user: code.userID,
        password: code.password
      )
      codeAppairage = ""
    }
  }
}
