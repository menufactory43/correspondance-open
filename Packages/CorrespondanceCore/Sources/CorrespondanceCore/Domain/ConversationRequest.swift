import Foundation

/// Une demande : une conversation entrante d'un inconnu, tenue hors de la file
/// tant qu'on ne l'a pas acceptée.
///
/// Aucun pont mautrix (v26.08) n'expose aujourd'hui de drapeau « message
/// request » : ni `m.bridge`, ni `com.beeper.room_type` n'en disent un mot.
/// La demande se **déduit** donc, et la déduction est ici, pure et nommée,
/// plutôt qu'éparpillée dans deux stores. Le jour où un pont l'annoncera, il
/// n'y aura qu'un signal de plus à passer à `RequestPolicy.isRequest`.
public enum ConversationRequest {
  /// Ce que l'utilisateur a décidé. L'absence de décision est ce qui fait la
  /// demande : accepter la fait entrer dans la file, refuser la range.
  public enum Decision: String, Codable, Sendable, Hashable {
    case accepted
    case declined
  }
}

/// Les signaux qui font — ou non — une demande. Un type nommé plutôt que
/// quatre booléens à la file : chaque appelant dit ce qu'il sait, et ce qu'il
/// ne sait pas garde une valeur qui ne piège personne.
public struct RequestSignals: Sendable, Equatable {
  /// Ai-je déjà écrit dans ce fil ? Répondre à quelqu'un, c'est l'accepter.
  ///
  /// `nil` = **on ne sait pas** — le fil n'a pas été chargé. Dans le doute on
  /// ne range personne : une conversation ordinaire qui disparaîtrait de la
  /// file coûte infiniment plus cher qu'une demande qu'on voit une fois de trop.
  public var hasWrittenBack: Bool?
  /// Le correspondant est-il quelqu'un que je connais — carnet d'adresses,
  /// contact fusionné ? Le Mac le sait ; l'iPhone, en v1, ne le sait pas
  /// encore (pas de carnet d'adresses) et répond `false`.
  public var isKnownCorrespondent: Bool
  /// Le réseau lui-même annonce une demande. Aucun pont mautrix v26.08 ne le
  /// fait aujourd'hui (voir `MatrixRoomModel.isNetworkFlaggedRequest`) ; le
  /// jour où l'un le fera, ce drapeau suffira, sans rien déduire.
  public var isFlaggedByNetwork: Bool

  public init(
    hasWrittenBack: Bool?,
    isKnownCorrespondent: Bool = false,
    isFlaggedByNetwork: Bool = false
  ) {
    self.hasWrittenBack = hasWrittenBack
    self.isKnownCorrespondent = isKnownCorrespondent
    self.isFlaggedByNetwork = isFlaggedByNetwork
  }
}

public enum RequestPolicy {
  /// Cette conversation est-elle une demande en attente ?
  ///
  /// D'abord ce qui disqualifie, toujours : une décision déjà prise, un fil
  /// non bridgé (iMessage n'a pas de salon où écrire la décision, et personne
  /// n'y « demande » rien), un groupe (on en part, on ne l'accepte pas), un fil
  /// de catalogue sans message.
  ///
  /// Ensuite, deux façons d'en être une : le réseau le dit, ou bien on l'a
  /// **prouvé** — fil chargé, pas une ligne de moi dedans, et personne de connu
  /// en face. Tant qu'on n'a pas chargé le fil, `hasWrittenBack` vaut `nil` et
  /// la conversation reste dans la file : on ne range jamais sur un soupçon.
  public static func isRequest(
    _ conversation: Conversation,
    signals: RequestSignals,
    decision: ConversationRequest.Decision?
  ) -> Bool {
    guard decision == nil else { return false }
    guard conversation.network.isMatrixBridged else { return false }
    guard !conversation.isGroup else { return false }
    guard conversation.hasLivePreview else { return false }
    if signals.isFlaggedByNetwork { return true }
    guard signals.hasWrittenBack == false else { return false }
    guard !signals.isKnownCorrespondent else { return false }
    return true
  }
}
