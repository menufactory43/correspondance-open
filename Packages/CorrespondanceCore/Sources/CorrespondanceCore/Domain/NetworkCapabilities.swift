import Foundation

/// Ce qu'un réseau accepte qu'on lui demande, en un seul endroit.
///
/// Sans cette table, chaque geste nouveau se met à écrire « sauf WhatsApp » au
/// milieu d'une vue, et l'app finit par offrir des boutons qui échouent par
/// construction. La règle est l'inverse : **une action que le pont ne porte pas
/// ne s'affiche pas**. Mieux vaut un geste absent qu'une correction que
/// personne d'autre ne voit.
///
/// Ce que la table dit vient des ponts mautrix, pas des réseaux : un réseau
/// **sait** peut-être modifier un message, mais si le pont ne relaie pas le
/// `m.replace`, la correction reste chez nous — donc, pour l'app, la capacité
/// n'existe pas.
///
/// La source de vérité se lit sur le Relais, pas dans nos souvenirs : chaque
/// pont bridgev2 publie ce qu'il porte dans l'état `com.beeper.room_features`
/// du salon (`edit: 2` = pleinement porté, `edit_max_age` en secondes). Les
/// valeurs ci-dessous en viennent, relevées le 2026-09-02 ; c'est là qu'il faut
/// retourner après chaque montée de version d'un pont.
public struct NetworkCapabilities: Sendable, Hashable {
  /// Modifier un message déjà parti (`m.replace` relayé jusqu'au réseau).
  public var editsSentMessages: Bool
  /// Délai au-delà duquel le réseau refuse la correction, compté depuis
  /// l'envoi du message d'origine. `nil` : aucune limite de temps.
  ///
  /// Une capacité n'est pas toute d'un bloc : Meta relaie bien le `m.replace`,
  /// mais **quinze minutes** seulement. Passé ce délai, la correction part,
  /// arrive au pont, et meurt là — l'app l'applique chez elle, le réseau garde
  /// le texte d'origine, et la correction n'existe que pour nous. C'est le pire
  /// des cas : pas une erreur, un mensonge silencieux. D'où ce champ.
  public var editWindow: TimeInterval?
  /// Délai au-delà duquel le réseau refuse la suppression pour tout le monde
  /// (`delete_max_age` du pont). `nil` : aucune limite — Meta laisse retirer un
  /// message de n'importe quand.
  public var deleteWindow: TimeInterval?
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
    editWindow: TimeInterval? = nil,
    deleteWindow: TimeInterval? = nil,
    renamesGroup: Bool = false,
    removesMember: Bool = false,
    addsMember: Bool = false,
    createsGroup: Bool = false,
    sendsVoiceMessages: Bool = false
  ) {
    self.editsSentMessages = editsSentMessages
    self.editWindow = editWindow
    self.deleteWindow = deleteWindow
    self.renamesGroup = renamesGroup
    self.removesMember = removesMember
    self.addsMember = addsMember
    self.createsGroup = createsGroup
    self.sendsVoiceMessages = sendsVoiceMessages
  }

  /// Un délai en toutes lettres — « 15 minutes », « 48 heures ».
  static func windowLabelFR(_ window: TimeInterval?) -> String? {
    guard let window else { return nil }
    if window >= 3600 {
      let heures = Int(window / 3600)
      return heures == 1 ? "1 heure" : "\(heures) heures"
    }
    let minutes = Int(window / 60)
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }

  /// Ce que chaque réseau porte, réseau par réseau.
  ///
  /// - **iMessage** ne passe par aucun pont : AppleScript n'envoie qu'un
  ///   message nu, et l'automatisation Accessibilité (le menu « Modifier » de
  ///   Messages, ≤ 15 min) est un chemin à part que le magasin traite seul —
  ///   elle ne se déclare pas ici.
  /// - **WhatsApp** et **Signal** : ils modifient, eux aussi. Leurs ponts
  ///   l'annoncent (`edit: 2`, « pleinement porté ») dans le
  ///   `com.beeper.room_features` de chaque salon — WhatsApp dans les quinze
  ///   minutes, Signal dans les vingt-quatre heures et dix corrections. Ils
  ///   relaient par ailleurs le nom du groupe et le retrait.
  /// - **Instagram** et **Messenger** : les deux réseaux de Meta, les deux mêmes
  ///   capacités — c'est le même connecteur derrière, à un binaire près. La
  ///   correction y passe, mais seulement dans les quinze minutes : le pont annonce lui-même `edit_max_age: 900` dans le
  ///   `com.beeper.room_features` du salon, parce que c'est la règle que Meta
  ///   applique de son côté. Au-delà, le geste ne s'affiche plus. En revanche le pont ne relaie
  ///   ni le nom du groupe ni le retrait — même prudence que `relaysGroupLeave`,
  ///   qui y est déjà faux pour l'un comme pour l'autre.
  /// - **La note à soi** est un salon à nous : rien ne s'y oppose, mais il n'y
  ///   a personne à y ajouter ni à en retirer.
  ///
  /// Créer un groupe passe par la commande `create-group` de bridgev2, que
  /// seuls deux ponts implémentent : mautrix-whatsapp (v0.12.5+) et
  /// mautrix-signal (v0.8.7+). mautrix-meta l'annonce en « support initial des
  /// groupes NON chiffrés » : tant que ce n'est pas vérifié sur un vrai compte,
  /// Instagram et Messenger restent à non — un groupe qu'on croit avoir créé et
  /// qui n'existe pas est pire que pas de bouton du tout.
  public static func of(_ network: MessageNetwork) -> NetworkCapabilities {
    switch network {
    case .iMessage:
      NetworkCapabilities()
    case .signal:
      NetworkCapabilities(
        editsSentMessages: true,
        editWindow: 24 * 3600,
        deleteWindow: 24 * 3600,
        renamesGroup: true,
        removesMember: true,
        addsMember: true,
        createsGroup: true,
        sendsVoiceMessages: true
      )
    case .whatsapp:
      NetworkCapabilities(
        editsSentMessages: true,
        editWindow: 15 * 60,
        deleteWindow: 48 * 3600,
        renamesGroup: true,
        removesMember: true,
        addsMember: true,
        createsGroup: true,
        sendsVoiceMessages: true
      )
    case .instagram, .messenger:
      NetworkCapabilities(
        editsSentMessages: true,
        editWindow: 15 * 60,
        addsMember: true,
        sendsVoiceMessages: true
      )
    // X : lu dans `pkg/connector/capabilities.go` de mautrix-twitter v26.08
    // (`fi.mau.twitter.capabilities.2026_01_08`) — `Edit` pleinement porté,
    // dix corrections et quinze minutes ; `Delete` pleinement porté, sans
    // délai ; le nom du groupe et l'invitation relayés, pas le retrait ; aucun
    // type audio dans la table des fichiers, donc pas de vocal. Pas de
    // `create-group` non plus : X n'ouvre un groupe que depuis son app.
    case .twitter:
      NetworkCapabilities(
        editsSentMessages: true,
        editWindow: 15 * 60,
        renamesGroup: true,
        addsMember: true
      )
    case .selfNote:
      NetworkCapabilities(
        editsSentMessages: true,
        renamesGroup: true,
        sendsVoiceMessages: true
      )
    // Un agent lit du texte : pas de vocal, pas de groupe à gérer.
    case .agent:
      NetworkCapabilities(editsSentMessages: true)
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

  /// Ce réseau accepte-t-il **encore** une correction de ce message ?
  ///
  /// La capacité et le délai se posent ensemble : demander l'une sans l'autre,
  /// c'est réintroduire le bouton qui ment. Compté depuis l'envoi d'origine,
  /// jamais depuis la dernière correction — c'est ainsi que Meta compte.
  func acceptsEdit(sentAt: Date, now: Date = Date()) -> Bool {
    guard capabilities.editsSentMessages else { return false }
    guard let window = capabilities.editWindow else { return true }
    return now.timeIntervalSince(sentAt) < window
  }

  /// La fenêtre dite en toutes lettres — « 15 minutes », « 24 heures ». C'est
  /// la seule façon honnête d'expliquer un refus : le délai varie d'un réseau
  /// à l'autre, un message figé mentirait pour trois d'entre eux sur quatre.
  var editWindowLabelFR: String? { NetworkCapabilities.windowLabelFR(capabilities.editWindow) }

  /// Ce réseau accepte-t-il **encore** de retirer ce message de partout ?
  ///
  /// Signal ferme à 24 h, WhatsApp à 48 h ; Meta ne ferme pas. Passé l'heure,
  /// le pont refuse en silence : la bulle disparaîtrait de chez nous et de
  /// nulle part ailleurs — exactement le mensonge que la correction faisait.
  func acceptsDeleteForEveryone(sentAt: Date, now: Date = Date()) -> Bool {
    guard let window = capabilities.deleteWindow else { return true }
    return now.timeIntervalSince(sentAt) < window
  }

  /// Le délai de suppression, en toutes lettres.
  var deleteWindowLabelFR: String? { NetworkCapabilities.windowLabelFR(capabilities.deleteWindow) }

  /// Peut-on renommer un groupe de ce réseau, et le pont le relaiera-t-il ?
  var supportsGroupRename: Bool { capabilities.renamesGroup }

  /// Peut-on retirer quelqu'un d'un groupe de ce réseau ?
  var supportsMemberRemoval: Bool { capabilities.removesMember }

  /// Peut-on ajouter quelqu'un à un groupe de ce réseau ?
  var supportsMemberInvite: Bool { capabilities.addsMember }

  /// Peut-on enregistrer et envoyer un vocal sur ce réseau ?
  var supportsVoiceMessages: Bool { capabilities.sendsVoiceMessages }
}

/// Les délais de l'automatisation Messages, le chemin qui ne passe par aucun
/// pont et ne se déclare donc pas dans la table.
///
/// Ce sont ceux de Messages lui-même : passé l'heure, l'entrée disparaît du
/// menu de l'app d'Apple, et l'AppleScript qui la cherche ne trouve rien —
/// l'échec serait une alerte au lieu d'un geste absent.
public enum MessagesAutomationWindow {
  /// « Modifier » : quinze minutes après l'envoi (et cinq corrections au plus,
  /// que nous ne comptons pas — le délai tombe le premier dans les faits).
  public static let edit: TimeInterval = 15 * 60
  /// « Annuler l'envoi » : deux minutes.
  public static let undoSend: TimeInterval = 2 * 60

  /// Le geste est-il encore dans sa fenêtre ?
  public static func isOpen(_ window: TimeInterval, since sentAt: Date, now: Date = Date()) -> Bool {
    now.timeIntervalSince(sentAt) < window
  }
}
