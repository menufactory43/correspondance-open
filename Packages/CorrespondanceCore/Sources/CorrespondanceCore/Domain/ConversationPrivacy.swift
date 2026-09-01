import CorrespondanceMatrixClient
import Foundation

/// Ce qu'on peut honnêtement dire de la confidentialité d'une conversation.
///
/// C'est la première pierre du chantier E, et la seule qui doive être juste
/// **avant** d'écrire une ligne de cryptographie : *un cadenas qui ment est
/// pire que pas de cadenas.*
///
/// Le fait à ne jamais maquiller : **une conversation pontée ne sera jamais
/// chiffrée de bout en bout, quoi qu'on fasse.** Le pont détient les clés du
/// réseau distant — il déchiffre pour traduire, c'est sa fonction. Chiffrer la
/// room Matrix d'un portail WhatsApp protégerait le trajet entre l'app et le
/// Relais, pas la conversation : le pont, lui, lit tout. Appeler ça
/// « chiffré de bout en bout » serait un mensonge d'interface.
public enum ConversationPrivacy: String, Sendable, Equatable, CaseIterable {
  /// Room Matrix native, chiffrée : personne d'autre que les participants ne
  /// lit, l'hébergeur du Relais compris. C'est ce que le chantier E apporte.
  case chiffree
  /// Room Matrix native, en clair sur le Relais. Le cas d'aujourd'hui.
  case relaisSeul
  /// Portail d'un pont : le pont déchiffre par construction, et le réseau
  /// d'origine a ses propres règles.
  case pontee

  public var labelFR: String {
    switch self {
    case .chiffree: "Chiffré de bout en bout"
    case .relaisSeul: "Chiffré jusqu'au Relais"
    case .pontee: "Passe par un pont"
    }
  }

  /// Ce qu'on affiche quand quelqu'un demande ce que ça veut dire. Aucune de
  /// ces phrases ne promet plus que ce qui est vrai.
  public var explanationFR: String {
    switch self {
    case .chiffree:
      "Seuls les participants peuvent lire. Même la machine qui héberge le Relais n'y a pas accès."
    case .relaisSeul:
      "Le trajet est chiffré, mais la machine qui héberge le Relais peut lire. "
        + "Si c'est ta machine, c'est toi ; si quelqu'un l'héberge pour toi, c'est lui."
    case .pontee:
      "Le pont traduit les messages entre ce réseau et le Relais : il les lit au passage. "
        + "Rien de ce qu'on ferait ici n'y changerait quelque chose."
    }
  }

  /// Vrai seulement pour le cadenas plein. Les deux autres cas ont leur propre
  /// pictogramme — jamais celui du chiffrement de bout en bout.
  public var showsClosedLock: Bool { self == .chiffree }

  /// Ce qu'une room raconte d'elle-même : son event d'état `m.room.encryption`
  /// et son appartenance à un pont.
  ///
  /// L'ordre compte : **pontée gagne toujours**. Une room de portail marquée
  /// chiffrée reste une conversation que le pont lit — la marque Matrix ne dit
  /// rien du réseau d'origine.
  public static func of(isBridged: Bool, encryptionAlgorithm: String?) -> ConversationPrivacy {
    if isBridged { return .pontee }
    guard let algorithm = encryptionAlgorithm, !algorithm.isEmpty else { return .relaisSeul }
    // On ne reconnaît que ce qu'on sait déchiffrer. Un algorithme inconnu n'est
    // pas une garantie : c'est une room qu'on ne saura pas lire.
    return algorithm == "m.megolm.v1.aes-sha2" ? .chiffree : .relaisSeul
  }

  /// La même chose, depuis l'état de la room.
  public static func of(isBridged: Bool, state: [MatrixEvent]) -> ConversationPrivacy {
    let algorithm = state.first { $0.type == "m.room.encryption" }?
      .content?.string(at: "algorithm")
    return of(isBridged: isBridged, encryptionAlgorithm: algorithm)
  }
}
