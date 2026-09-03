import Foundation

public enum MessageNetwork: String, CaseIterable, Identifiable, Codable, Sendable {
  case iMessage
  case signal
  case whatsapp
  case instagram
  /// Messenger passe par le même pont que les autres réseaux de Meta, mais par
  /// son propre binaire (mautrix-meta, tag sans `ig-`) et son propre salon de
  /// gestion : côté app, c'est un réseau à part entière, pas une variante d'Instagram.
  case messenger
  /// X, l'ex-Twitter : ses messages privés, par mautrix-twitter. Le pont garde
  /// son nom d'origine partout où ça se voit dans le Relais (`@twitterbot`,
  /// ghosts `twitter_…`, protocole `twitter`) ; l'utilisateur, lui, ne lit que « X ».
  case twitter
  /// Slack, par mautrix-slack. Un compte, c'est un espace de travail : ses DM,
  /// ses DM de groupe, et ses canaux — qui arrivent comme des groupes, une ligne
  /// par canal, exactement comme un groupe WhatsApp. Rien de nouveau à l'écran.
  case slack
  /// La note à soi : le seul fil qui ne vienne d'aucun réseau. Il vit dans le
  /// Relais, dans un salon dont on est le seul membre — de quoi se laisser un
  /// mot, une adresse, une photo, et le retrouver sur l'autre appareil.
  case selfNote
  /// Un tête-à-tête avec un agent : un salon natif du Relais, marqué comme tel
  /// à la création (`AgentWire.conversationType`), où l'agent répond à tout
  /// message sans qu'on le nomme. Pas de pont, pas de contact : l'autre, c'est
  /// un moteur qui tourne quelque part.
  case agent

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .iMessage: "iMessage"
    case .signal: "Signal"
    case .whatsapp: "WhatsApp"
    case .instagram: "Instagram"
    case .messenger: "Messenger"
    case .twitter: "X"
    case .slack: "Slack"
    case .selfNote: "Note à soi"
    case .agent: "Agent"
    }
  }

  public var systemImage: String {
    switch self {
    case .iMessage: "message.fill"
    case .signal: "antenna.radiowaves.left.and.right"
    case .whatsapp: "phone.bubble.fill"
    case .instagram: "camera.fill"
    // L'éclair de Messenger, au plus près de ce que SF Symbols sait dire d'un
    // réseau qu'Apple ne nomme pas. Disponible depuis macOS 11 / iOS 14.
    case .messenger: "bolt.horizontal.circle.fill"
    // Une croix, en gras dans la pastille : ce qu'un logo de X a de plus
    // reconnaissable, sans en copier le dessin.
    case .twitter: "xmark"
    // Le croisillon d'un canal : ce que Slack a de plus reconnaissable.
    case .slack: "number"
    case .selfNote: "note.text"
    case .agent: "sparkles"
    }
  }

  /// Passe par un homeserver Matrix (bridge mautrix) plutôt que par un transport natif.
  /// C'est le descripteur qui fait foi : un réseau bridgé est un réseau qui en a un.
  public var isMatrixBridged: Bool { bridge != nil }

  /// Ce fil passe-t-il par le Relais ? Tous les réseaux bridgés, **et** la note
  /// à soi — qui n'a pas de pont, mais bien un salon. Distinct de
  /// `isMatrixBridged`, qui répond « ce réseau a-t-il un bot à connecter ».
  public var livesOnRelay: Bool { isMatrixBridged || self == .selfNote || self == .agent }

  /// Réseaux bridgés, dans l'ordre de l'enum — ce qui pilote les boutons de Réglages.
  public static var matrixBridged: [MessageNetwork] { allCases.filter(\.isMatrixBridged) }

  /// `protocol.id` de l'event d'état `m.bridge` côté mautrix.
  public static func fromBridgeProtocol(_ protocolID: String) -> MessageNetwork? {
    MatrixBridgeDescriptor.network(ofProtocol: protocolID)
  }
}
