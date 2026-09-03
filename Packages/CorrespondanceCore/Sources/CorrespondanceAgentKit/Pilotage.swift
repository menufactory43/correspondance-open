import CorrespondanceMatrixClient
import Foundation

/// Le mode « répond seul » : l'agent envoie **au nom du propriétaire**, dans
/// un cadre d'une phrase, et passe la main dès qu'il en sort.
///
/// Le cadre est ce qui rend le mode supportable : « confirme ou déplace les
/// rendez-vous, rien d'autre ». Le moteur répond, ou dit exactement
/// `<hors-cadre>` et pourquoi — et c'est ici qu'on relit ce protocole. Pur,
/// parce qu'un texte mal lu enverrait au tiers la phrase « hors cadre : il
/// demande un prix » à la place d'une réponse.
public enum Pilotage {
  /// Ce que le moteur écrit quand il refuse de répondre seul. Défini dans
  /// `Trigger`, à côté du prompt qui l'exige.
  public static let horsCadre = Trigger.horsCadre

  /// Combien de réponses pilotées par heure et par salon, au plus. Un cadre
  /// mal écrit, un tiers bavard : ce plafond est ce qui borne le dégât avant
  /// que le propriétaire ne regarde.
  public static let plafondParHeure = 10

  public enum Verdict: Equatable, Sendable {
    /// À envoyer, tel quel, marqué `pilotedKey`.
    case reponse(String)
    /// L'agent passe la main : proposition `handover` avec la raison, et un
    /// avis au propriétaire.
    case horsCadre(raison: String)
  }

  /// Relit ce que le moteur a répondu. `<hors-cadre>` en tête — quelle que
  /// soit la casse, avec ou sans ponctuation après — passe la main ; le
  /// reste de la ligne est la raison. Tout autre texte est la réponse.
  /// Un texte vide passe la main aussi : on n'envoie pas du vide à un tiers.
  public static func lire(_ texte: String) -> Verdict {
    let net = texte.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !net.isEmpty else { return .horsCadre(raison: "le moteur n'a rien répondu") }
    // Le moteur cite parfois le marqueur entre accents graves, comme dans le prompt.
    let sansGraves = net.hasPrefix("`") ? net.replacingOccurrences(of: "`", with: "") : net
    guard sansGraves.lowercased().hasPrefix(horsCadre) else { return .reponse(net) }
    var raison = Substring(sansGraves.dropFirst(horsCadre.count))
    while let premier = raison.first, premier.isWhitespace || premier == ":" || premier == "—" || premier == "-" || premier == "," {
      raison = raison.dropFirst()
    }
    let dite = raison.trimmingCharacters(in: .whitespacesAndNewlines)
    return .horsCadre(raison: dite.isEmpty ? "le message sort du cadre" : dite)
  }
}
