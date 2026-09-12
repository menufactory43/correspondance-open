import CorrespondanceCore
import Foundation

/// Une rangée du fil, telle que la liste la pose.
///
/// Le fil n'est plus une pile paresseuse de groupes mais une liste de rangées
/// : une rangée, un élément, une hauteur mesurée à part. C'est ce que fait la
/// `ConversationCollectionView` de Signal, et c'est ce qui permet d'ancrer le
/// fil sur un message précis — la barre des non-lus, une citation — au lieu de
/// viser un décalage en points au-dessus de rangées seulement estimées.
struct ThreadRow: Identifiable, Equatable {
  /// L'identité d'une rangée ne change jamais : c'est elle qui dit à la liste
  /// ce qui est arrivé, ce qui est parti, et ce qui a seulement changé d'aspect.
  let id: String
  var kind: Kind

  enum Kind: Equatable {
    /// La roue de l'historique en cours de chargement, en tête.
    case loadingOlder
    /// « … messages plus tôt » — le pli de Focus.
    case foldedHeader(Int)
    /// L'heure posée en travers, et le réseau d'où vient la suite.
    case timeSeparator(Date, MessageNetwork?)
    /// La barre de Signal : « 3 messages non lus », là où la lecture s'arrête.
    case unreadMark(Int)
    /// « X a ajouté Y » — en travers du fil, sans auteur.
    case systemEvent(String)
    case bubble(Bubble)
    /// Les trois points, au bas du fil, là où la bulle apparaîtra.
    case typing(String?)
    /// « Envoyé · Vu », sous le dernier message sortant.
    case receipt(String)
  }

  /// Une bulle et ce que sa prise de parole lui donne : son nom, sa place dans
  /// le groupe, et la photo de l'auteur quand elle en termine un.
  struct Bubble: Equatable {
    var message: ChatMessage
    /// Le nom écrit au-dessus — sur la première bulle du groupe seulement.
    var senderLabel: String?
    /// Le nom que porte la bulle dans le fil, pour l'aperçu d'appui long.
    var groupSenderLabel: String?
    var position: BubblePosition
    var isFromMe: Bool
    /// L'auteur de la prise de parole. Non nul sur la DERNIÈRE bulle d'un
    /// groupe reçu : la photo se pose sur son bord bas, comme sur le Mac.
    var avatarSource: ChatMessage?
    /// Un envoi encore en sursis, qui n'est plus le dernier : il garde son
    /// « Annuler » sous lui. Vient du store, pas du message — mais il entre
    /// DANS la rangée, sinon la cellule déjà posée ne se referait jamais.
    var canCancelPending = false
    /// La bulle vers laquelle on vient de sauter, surlignée un instant.
    var isFlashed = false
  }

  /// Le message porté par la rangée, quand elle en porte un.
  var message: ChatMessage? {
    switch kind {
    case .bubble(let bubble): bubble.message
    default: nil
    }
  }
}

/// Le fil mis à plat : des groupes aux rangées.
enum ThreadRows {
  /// Le préfixe des identifiants de rangée qui ne sont pas des bulles. Une
  /// bulle garde l'identifiant de son message — c'est lui qu'on vise pour
  /// sauter à une citation.
  static let unreadMarkID = "correspondance.fil.non-lus"
  static let typingID = "correspondance.fil.ecrit"
  static let receiptID = "correspondance.fil.accuse"
  static let loadingID = "correspondance.fil.historique"
  static let foldedID = "correspondance.fil.pli"

  /// Construit la liste des rangées.
  ///
  /// - Parameter unreadCount: ce qui n'était pas lu à l'ouverture du fil. La
  ///   barre se pose juste avant le premier de ces messages — et seulement
  ///   s'il en reste un à montrer, jamais en tête d'un historique tronqué.
  /// - Parameter rowID: l'identité de rangée d'un message. Normalement la
  ///   sienne — mais la copie que le Relais rend d'un message que je viens
  ///   d'envoyer garde l'identité de l'écho local qu'elle remplace. Sans ça,
  ///   la liste voit partir une rangée et en voir arriver une autre, refait la
  ///   cellule, et l'envoi scintille.
  static func rows(
    groups: [MessageGroup],
    messages: [ChatMessage],
    unreadCount: Int,
    isLoadingOlder: Bool,
    foldedAwayCount: Int?,
    typingLabel: String?,
    receiptLabel: String?,
    rowID: (ChatMessage) -> String = \.id
  ) -> [ThreadRow] {
    var rows: [ThreadRow] = []
    if isLoadingOlder { rows.append(ThreadRow(id: loadingID, kind: .loadingOlder)) }
    if let hidden = foldedAwayCount, hidden > 0 {
      rows.append(ThreadRow(id: foldedID, kind: .foldedHeader(hidden)))
    }

    let mark = UnreadMark.place(in: messages, unreadCount: unreadCount)

    for group in groups {
      if let separator = group.timeSeparator {
        rows.append(
          ThreadRow(
            id: "\(group.id).heure",
            kind: .timeSeparator(separator, group.networkOrigin)
          ))
      }
      for (index, message) in group.messages.enumerated() {
        // La barre se pose AVANT le message, séparateur d'heure compris : ce
        // qui est neuf commence sous elle, son horodatage avec.
        if let mark, message.id == mark.messageID {
          rows.append(ThreadRow(id: unreadMarkID, kind: .unreadMark(mark.count)))
        }
        if let text = message.systemEventText {
          rows.append(ThreadRow(id: rowID(message), kind: .systemEvent(text)))
          continue
        }
        let position = BubblePosition(index: index, count: group.messages.count)
        rows.append(
          ThreadRow(
            id: rowID(message),
            kind: .bubble(
              ThreadRow.Bubble(
                message: message,
                senderLabel: index == 0 ? group.senderLabel : nil,
                groupSenderLabel: group.senderLabel,
                position: position,
                isFromMe: group.isFromMe,
                // La photo regarde la fin de la prise de parole, pas son
                // début : elle se pose sur le bord bas de la dernière bulle.
                avatarSource: !group.isFromMe && position.endsGroup
                  ? group.messages.first
                  : nil
              ))
          ))
      }
    }

    if let typingLabel { rows.append(ThreadRow(id: typingID, kind: .typing(typingLabel))) }
    if let receiptLabel { rows.append(ThreadRow(id: receiptID, kind: .receipt(receiptLabel))) }
    return rows
  }

}
