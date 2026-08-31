import Foundation

/// Ce qu'un réseau accepte qu'on lui demande, en un seul endroit.
///
/// Sans cette table, chaque geste nouveau se met à écrire « sauf WhatsApp » au
/// milieu d'une vue, et l'app finit par offrir des boutons qui échouent par
/// construction. La règle est l'inverse : **une action que le pont ne porte pas
/// ne s'affiche pas**. Mieux vaut un geste absent qu'une correction que
/// personne d'autre ne voit.
///
/// Ce que la table dit vient des ponts mautrix, pas des réseaux : WhatsApp
/// **sait** modifier un message, mais si le pont ne relaie pas le `m.replace`,
/// la correction reste chez nous — donc, pour l'app, la capacité n'existe pas.
public struct NetworkCapabilities: Sendable, Hashable {
  /// Modifier un message déjà parti (`m.replace` relayé jusqu'au réseau).
  public var editsSentMessages: Bool
  /// Renommer un groupe (`m.room.name` relayé).
  public var renamesGroup: Bool
  /// Retirer quelqu'un d'un groupe (`kick` relayé).
  public var removesMember: Bool
  /// Ajouter quelqu'un à un groupe (invitation d'un ghost du pont).
  public var addsMember: Bool
  /// Créer un groupe depuis l'app.
  public var createsGroup: Bool
  /// Envoyer un message vocal (`m.audio` / `org.matrix.msc3245.voice`).
  public var sendsVoiceMessages: Bool

  public init(
    editsSentMessages: Bool = false,
    renamesGroup: Bool = false,
    removesMember: Bool = false,
    addsMember: Bool = false,
    createsGroup: Bool = false,
    sendsVoiceMessages: Bool = false
  ) {
    self.editsSentMessages = editsSentMessages
    self.renamesGroup = renamesGroup
    self.removesMember = removesMember
    self.addsMember = addsMember
    self.createsGroup = createsGroup
    self.sendsVoiceMessages = sendsVoiceMessages
  }

  /// Ce que chaque réseau porte, réseau par réseau.
  ///
  /// - **iMessage** ne passe par aucun pont : AppleScript n'envoie qu'un
  ///   message nu, et l'automatisation Accessibilité (le menu « Modifier » de
  ///   Messages, ≤ 15 min) est un chemin à part que le magasin traite seul —
  ///   elle ne se déclare pas ici.
  /// - **WhatsApp** et **Signal** : les ponts ne remontent pas le `m.replace`
  ///   vers le réseau ; une correction envoyée là-bas ne serait visible que
  ///   chez nous. Ils relaient en revanche le nom du groupe et le retrait.
  /// - **Instagram / Meta** : le seul `m.replace` que mautrix porte jusqu'au
  ///   réseau. En revanche le pont ne relaie ni le nom du groupe ni le retrait
  ///   — même prudence que `relaysGroupLeave`, qui y est déjà faux.
  /// - **La note à soi** est un salon à nous : rien ne s'y oppose, mais il n'y
  ///   a personne à y ajouter ni à en retirer.
  ///
  /// Créer un groupe n'est vrai nulle part : aucun pont n'expose la création de
  /// portail depuis Matrix (cf. le commit du lot C).
  public static func of(_ network: MessageNetwork) -> NetworkCapabilities {
    switch network {
    case .iMessage:
      NetworkCapabilities()
    case .signal:
      NetworkCapabilities(
        renamesGroup: true,
        removesMember: true,
        addsMember: true,
        sendsVoiceMessages: true
      )
    case .whatsapp:
      NetworkCapabilities(
        renamesGroup: true,
        removesMember: true,
        addsMember: true,
        sendsVoiceMessages: true
      )
    case .instagram:
      NetworkCapabilities(
        editsSentMessages: true,
        addsMember: true,
        sendsVoiceMessages: true
      )
    case .selfNote:
      NetworkCapabilities(
        editsSentMessages: true,
        renamesGroup: true,
        sendsVoiceMessages: true
      )
    }
  }
}

public extension MessageNetwork {
  var capabilities: NetworkCapabilities { NetworkCapabilities.of(self) }

  /// Peut-on modifier un message déjà envoyé sur ce réseau ?
  ///
  /// iMessage l'a aussi, mais par un tout autre chemin (l'automatisation
  /// Messages) : le magasin le traite à part, il n'est pas dans la table.
  var supportsEditing: Bool { capabilities.editsSentMessages }

  /// Peut-on renommer un groupe de ce réseau, et le pont le relaiera-t-il ?
  var supportsGroupRename: Bool { capabilities.renamesGroup }

  /// Peut-on retirer quelqu'un d'un groupe de ce réseau ?
  var supportsMemberRemoval: Bool { capabilities.removesMember }

  /// Peut-on ajouter quelqu'un à un groupe de ce réseau ?
  var supportsMemberInvite: Bool { capabilities.addsMember }

  /// Peut-on enregistrer et envoyer un vocal sur ce réseau ?
  var supportsVoiceMessages: Bool { capabilities.sendsVoiceMessages }
}
