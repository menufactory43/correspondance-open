import CorrespondanceCore
import Foundation
import Intents
import UserNotifications

/// La notification qui montre la personne, pas l'app.
///
/// Messages, WhatsApp, Signal, Telegram : depuis iOS 15, leurs notifications
/// portent la photo du contact — ou du groupe — à la place de l'icône de l'app,
/// qui passe en petite pastille. C'est l'API « Communication Notifications » :
/// on décrit le message reçu comme une intention `INSendMessageIntent`, on la
/// donne au système, et `UNNotificationContent.updating(from:)` recompose la
/// notification autour de l'expéditeur. Il faut la capacité
/// `com.apple.developer.usernotifications.communication` et
/// `NSUserActivityTypes` dans l'Info.plist de l'app — sans quoi le système
/// rend le contenu inchangé, sans un mot.
///
/// Partagé entre l'extension (push distant) et l'app (notification locale) :
/// les deux doivent dessiner la même chose, sinon la même personne aurait deux
/// visages selon que l'app tournait ou non.
enum CommunicationNotification {
  /// Ce qu'on met dans l'intention : qui, quel fil, quelle photo.
  struct Identity {
    /// L'identifiant stable du fil — le salon : c'est lui qui groupe les
    /// notifications et que Siri retient.
    var conversationID: String
    var senderName: String
    var conversationTitle: String?
    var network: MessageNetwork?
    var isGroup: Bool
    var avatar: Data?
    /// Quelques membres, par leur nom. Requis pour qu'iOS classe la
    /// notification en groupe : sans destinataires, `updating(from:)` la
    /// traite en tête-à-tête et ignore la photo du groupe.
    var memberNames: [String] = []
  }

  /// Le contenu recomposé autour de la personne. En cas d'échec — capacité
  /// absente, intention refusée — le contenu d'origine, tel quel.
  static func content(
    _ content: UNNotificationContent,
    body: String,
    identity: Identity
  ) -> UNNotificationContent {
    let intent = makeIntent(body: body, identity: identity)
    donate(intent)
    return (try? content.updating(from: intent)) ?? content
  }

  /// Le nom sous lequel la personne apparaît, réseau compris : deux fils de la
  /// même personne sur deux réseaux restent distinguables sur l'écran
  /// verrouillé, comme dans le titre classique.
  static func displayName(_ name: String, network: MessageNetwork?, showsNetwork: Bool) -> String {
    guard showsNetwork, let network else { return name }
    return "\(name) · \(network.labelFR)"
  }

  private static func makeIntent(body: String, identity: Identity) -> INSendMessageIntent {
    let image = identity.avatar.map { INImage(imageData: $0) }
    // En tête-à-tête, la photo est celle de l'auteur ; en groupe, elle va sur
    // le groupe (ci-dessous), et l'auteur n'en a pas — c'est ce qui fait que
    // le système montre la photo du groupe et non celle de la personne.
    let sender = INPerson(
      personHandle: INPersonHandle(value: identity.conversationID, type: .unknown),
      nameComponents: nil,
      displayName: displayName(identity.senderName, network: identity.network, showsNetwork: !identity.isGroup),
      image: identity.isGroup ? nil : image,
      contactIdentifier: nil,
      customIdentifier: identity.conversationID,
      isMe: false,
      suggestionType: .none
    )
    var groupName: INSpeakableString?
    if identity.isGroup, let title = identity.conversationTitle, !title.isEmpty {
      groupName = INSpeakableString(spokenPhrase: displayName(title, network: identity.network, showsNetwork: true))
    }
    var recipients: [INPerson]?
    if identity.isGroup {
      recipients = identity.memberNames.enumerated().map { index, name in
        INPerson(
          personHandle: INPersonHandle(value: "\(identity.conversationID)#\(index)", type: .unknown),
          nameComponents: nil,
          displayName: name,
          image: nil,
          contactIdentifier: nil,
          customIdentifier: "\(identity.conversationID)#\(index)",
          isMe: false,
          suggestionType: .none
        )
      }
    }
    let intent = INSendMessageIntent(
      recipients: recipients,
      outgoingMessageType: .outgoingMessageText,
      content: body,
      speakableGroupName: groupName,
      conversationIdentifier: identity.conversationID,
      serviceName: identity.network?.labelFR,
      sender: sender,
      attachments: nil
    )
    if identity.isGroup, let image {
      intent.setImage(image, forParameterNamed: \.speakableGroupName)
    }
    return intent
  }

  /// Le don **sortant** : « j'écris à cette personne ». C'est celui que la
  /// rangée des visages de la feuille de partage lit — un don entrant dit qui
  /// m'a écrit, pas à qui j'envoie. Les messageries le font à chaque envoi ;
  /// on le fait aussi pour les fils récents à chaque rafraîchissement, pour
  /// que la rangée existe avant le premier message.
  static func donnerEnvoi(
    conversationID: String, title: String, network: MessageNetwork, isGroup: Bool, avatar: Data?
  ) {
    let image = avatar.map { INImage(imageData: $0) }
    let destinataire = INPerson(
      personHandle: INPersonHandle(value: conversationID, type: .unknown),
      nameComponents: nil,
      displayName: displayName(title, network: network, showsNetwork: true),
      image: image,
      contactIdentifier: nil,
      customIdentifier: conversationID,
      isMe: false,
      suggestionType: .instantMessageAddress
    )
    let groupe = isGroup
      ? INSpeakableString(spokenPhrase: displayName(title, network: network, showsNetwork: true))
      : nil
    let intent = INSendMessageIntent(
      recipients: [destinataire],
      outgoingMessageType: .outgoingMessageText,
      content: nil,
      speakableGroupName: groupe,
      conversationIdentifier: conversationID,
      serviceName: network.labelFR,
      sender: nil,
      attachments: nil
    )
    if isGroup, let image {
      intent.setImage(image, forParameterNamed: \.speakableGroupName)
    }
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .outgoing
    interaction.donate(completion: nil)
  }

  /// Le don est ce qui fait apparaître le fil dans les suggestions de partage
  /// et permet à Siri de le nommer. Il n'est pas requis pour la photo, mais
  /// c'est ce que font les messageries, et ça ne coûte rien.
  private static func donate(_ intent: INSendMessageIntent) {
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)
  }
}
