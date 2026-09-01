import Foundation

/// LE DÉCOUPAGE D'UNE MOSAÏQUE. Plusieurs photos envoyées d'un coup forment un
/// album, pas une pile : empilées, quatre photos font défiler la conversation
/// sur trois écrans et on ne voit plus qu'elles.
///
/// Deux photos se posent côte à côte, trois en une grande et deux petites,
/// quatre et plus en carré — au-delà de quatre, la dernière tuile porte le
/// compte de ce qu'elle cache. Les tuiles sont carrées dans les trois cas :
/// c'est la proportion de l'album ENTIER qui change, jamais celle d'une tuile.
public struct MediaAlbumLayout: Equatable, Sendable {
  /// Un média à sa place dans la mosaïque.
  public struct Tile: Equatable, Sendable {
    /// Rang du média dans le message.
    public let index: Int
    /// Ce que cette tuile cache derrière elle (« +3 »), zéro sinon.
    public let hiddenCount: Int

    public init(index: Int, hiddenCount: Int = 0) {
      self.index = index
      self.hiddenCount = hiddenCount
    }
  }

  /// Une colonne : sa part de la largeur, et les tuiles qui s'y empilent à
  /// hauteurs égales.
  public struct Column: Equatable, Sendable {
    public let widthFraction: Double
    public let tiles: [Tile]

    public init(widthFraction: Double, tiles: [Tile]) {
      self.widthFraction = widthFraction
      self.tiles = tiles
    }
  }

  public let columns: [Column]
  /// Largeur ÷ hauteur de l'album entier.
  public let aspectRatio: Double

  /// `nil` en dessous de deux médias : une photo seule reste une photo, montrée
  /// à sa propre proportion.
  public static func plan(count: Int) -> MediaAlbumLayout? {
    switch count {
    case ..<2:
      return nil
    case 2:
      return MediaAlbumLayout(
        columns: [
          Column(widthFraction: 0.5, tiles: [Tile(index: 0)]),
          Column(widthFraction: 0.5, tiles: [Tile(index: 1)]),
        ],
        aspectRatio: 2
      )
    case 3:
      return MediaAlbumLayout(
        columns: [
          Column(widthFraction: 2.0 / 3, tiles: [Tile(index: 0)]),
          Column(widthFraction: 1.0 / 3, tiles: [Tile(index: 1), Tile(index: 2)]),
        ],
        aspectRatio: 1.5
      )
    default:
      return MediaAlbumLayout(
        columns: [
          Column(widthFraction: 0.5, tiles: [Tile(index: 0), Tile(index: 2)]),
          Column(widthFraction: 0.5, tiles: [Tile(index: 1), Tile(index: 3, hiddenCount: count - 4)]),
        ],
        aspectRatio: 1
      )
    }
  }
}

/// LES ALBUMS DU FIL. Matrix n'a pas de « message à quatre photos » : quatre
/// photos envoyées d'un coup arrivent en quatre événements, à la seconde près.
/// Le fil les recollait en quatre bulles, et une conversation d'été devenait un
/// escalier de photos qu'on ne finissait plus de faire défiler.
///
/// Le recollage se fait ICI, avant le découpage en groupes : ce qui suit ne voit
/// qu'un seul message, qui porte toutes les photos et toutes leurs réactions.
/// L'album garde l'identité de sa PREMIÈRE photo — c'est elle que vise une
/// réaction posée sur la mosaïque.
public enum MediaAlbums {
  /// Deux photos plus éloignées que ça n'ont pas été envoyées ensemble.
  public static let window: TimeInterval = 60

  public static func merged(_ messages: [ChatMessage]) -> [ChatMessage] {
    var result: [ChatMessage] = []
    /// L'heure de la photo précédente : c'est d'elle qu'on mesure l'écart, pas
    /// de la première de l'album — six photos mettent du temps à monter.
    var previousAt: Date?
    for message in messages {
      if isPiece(message), var album = result.last, isPiece(album),
         let previousAt, message.sentAt.timeIntervalSince(previousAt) <= window,
         album.isFromMe == message.isFromMe, album.network == message.network,
         MessageGrouping.authorKey(album) == MessageGrouping.authorKey(message)
      {
        album.attachments += message.attachments
        album.reactions = union(album.reactions, message.reactions)
        result[result.count - 1] = album
      } else {
        result.append(message)
      }
      previousAt = isPiece(message) ? message.sentAt : nil
    }
    return result
  }

  /// Une photo nue : rien d'autre à dire que l'image elle-même. Une légende,
  /// une citation ou une correction rendent le message singulier — il garde
  /// alors sa bulle.
  private static func isPiece(_ message: ChatMessage) -> Bool {
    guard message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          message.replyTo?.isEmpty != false,
          message.poll == nil, !message.isRetracted, !message.isSystemEvent,
          !message.isAgentProposal, !message.isPending,
          message.editedAt == nil, message.expressiveEffectName == nil,
          message.linkPreview == nil
    else { return false }
    return !message.attachments.isEmpty && message.attachments.allSatisfy {
      ($0.isImage || $0.isVideo) && !$0.isGIF && !$0.isVoiceNote
    }
  }

  private static func union(_ lhs: [MessageReaction], _ rhs: [MessageReaction]) -> [MessageReaction] {
    var byEmoji: [String: MessageReaction] = [:]
    for reaction in lhs + rhs {
      var merged = byEmoji[reaction.emoji] ?? MessageReaction(emoji: reaction.emoji)
      merged.senders = Array(Set(merged.senders).union(reaction.senders)).sorted()
      merged.isMine = merged.isMine || reaction.isMine
      byEmoji[reaction.emoji] = merged
    }
    return byEmoji.values.sorted {
      $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji
    }
  }
}
