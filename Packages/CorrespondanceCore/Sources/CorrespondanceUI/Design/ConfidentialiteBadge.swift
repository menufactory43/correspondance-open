import CorrespondanceCore
import SwiftUI

/// Le pictogramme qui dit ce qu'on peut honnêtement promettre d'une
/// conversation — et qui **existe surtout pour ce qu'il ne montre pas**.
///
/// La fiche le disait déjà en toutes lettres (`ConfidentialiteAffichee`), mais
/// il fallait l'ouvrir pour le savoir. Une conversation qui passe par un pont
/// n'a pas l'air différente d'un salon chiffré tant qu'on n'a pas cliqué : le
/// signe doit donc être là **avant** qu'on demande, dans l'entête, à côté du
/// nom.
///
/// Il ne réinvente aucun mot : `ConfidentialiteAffichee` reste le seul endroit
/// qui décide du pictogramme et de la phrase. Ici on ne fait que les poser, et
/// le cadenas plein n'appartient qu'au salon natif chiffré.
public struct ConfidentialiteBadge: View {
  public let confidentialite: ConfidentialiteAffichee
  public let teinte: Color
  /// La taille du pictogramme. 11 dans une barre d'outils, 13 dans une fiche.
  public let taille: CGFloat

  public init(_ confidentialite: ConfidentialiteAffichee, teinte: Color, taille: CGFloat = 11) {
    self.confidentialite = confidentialite
    self.teinte = teinte
    self.taille = taille
  }

  public var body: some View {
    Image(systemName: confidentialite.symbole)
      .font(.system(size: taille, weight: .semibold))
      .foregroundStyle(teinte)
      .accessibilityLabel(confidentialite.libelleFR)
      .accessibilityHint(confidentialite.phraseFR)
      .help("\(confidentialite.libelleFR) — \(confidentialite.phraseFR)")
  }
}
