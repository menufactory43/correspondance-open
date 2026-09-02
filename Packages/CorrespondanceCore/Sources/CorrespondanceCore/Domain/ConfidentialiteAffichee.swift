import Foundation

/// Ce que la fiche d'une conversation montre du chiffrement : un pictogramme,
/// trois mots, une phrase franche.
///
/// `ConversationPrivacy` dit **ce qui est vrai** ; ce type dit **ce qu'on
/// affiche**. Les deux sont séparés parce que l'affichage a une contrainte que
/// le fait n'a pas : il doit tenir en une ligne et ne jamais suggérer plus que
/// ce qui est protégé.
///
/// La règle qui gouverne le tout : **un portail ne montre jamais le cadenas du
/// bout en bout.** L'installeur pose `encryption.default: true` sur les quatre
/// ponts depuis la phase 4 ; le salon du portail est donc bel et bien chiffré,
/// et un client naïf y mettrait un cadenas plein. Ce serait faux : le pont est
/// un appareil du salon, il déchiffre pour traduire. Le cadenas qu'on montre
/// alors est un cadenas **entrouvert**, et la phrase nomme celui qui lit.
public struct ConfidentialiteAffichee: Sendable, Equatable {
  public var etat: ConversationPrivacy
  /// Le salon Matrix porte-t-il `m.room.encryption` ?
  public var salonChiffre: Bool

  public init(etat: ConversationPrivacy, salonChiffre: Bool) {
    self.etat = etat
    self.salonChiffre = salonChiffre
  }

  /// Les trois états, dans les mots de l'écran.
  public var libelleFR: String {
    switch etat {
    case .chiffree: return "Chiffré"
    case .pontee: return salonChiffre ? "Chiffré par le pont" : "En clair"
    case .relaisSeul: return "En clair"
    }
  }

  /// `lock.fill` n'appartient qu'au premier cas. Les deux autres ont leur
  /// propre pictogramme, et on ne s'autorise pas à les confondre.
  public var symbole: String {
    switch etat {
    case .chiffree: return "lock.fill"
    case .pontee: return salonChiffre ? "lock.open.fill" : "arrow.triangle.swap"
    case .relaisSeul: return "lock.open"
    }
  }

  /// La phrase, quand quelqu'un veut savoir ce que ça veut dire.
  public var phraseFR: String {
    switch etat {
    case .chiffree:
      return ConversationPrivacy.chiffree.explanationFR
    case .pontee where salonChiffre:
      return "Le salon est chiffré jusqu'au pont, et le pont le déchiffre pour traduire vers "
        + "ce réseau : c'est sa fonction. Ce n'est donc pas du bout en bout."
    case .pontee:
      return ConversationPrivacy.pontee.explanationFR
    case .relaisSeul:
      return ConversationPrivacy.relaisSeul.explanationFR
    }
  }
}

extension Conversation {
  /// Ce que la fiche affiche pour cette conversation.
  public var confidentialite: ConfidentialiteAffichee {
    ConfidentialiteAffichee(etat: privacy, salonChiffre: encryptionAlgorithm != nil)
  }
}
