import Foundation

/// Ce qui distingue un pont mautrix d'un autre, en un seul endroit.
///
/// Sans ça, « whatsapp » finit écrit en dur dans le parseur, dans la reconnaissance des
/// ghosts, dans la commande envoyée au bot et dans trois vues. Ajouter Instagram voulait
/// alors dire retrouver toutes ces chaînes ; ici il suffit d'ajouter un descripteur.
struct MatrixBridgeDescriptor: Sendable, Hashable {
  /// Comment on prouve son identité au réseau distant.
  enum LoginFlow: Sendable, Hashable {
    /// Le bot poste un QR à scanner depuis le téléphone (WhatsApp).
    case qrCode
    /// L'utilisateur se connecte dans une fenêtre de navigation intégrée, et l'app
    /// transmet la session récoltée au bot (Instagram — Meta n'offre rien d'autre).
    case webSession
  }

  let network: MessageNetwork
  /// Localpart du bot de gestion : `@whatsappbot:serveur`, `@instagrambot:serveur`.
  let botLocalpart: String
  /// Préfixe des commandes, obligatoire hors salon de gestion (`!wa`, `!ig`).
  let commandPrefix: String
  /// Préfixe des ghosts : `@whatsapp_lid-123:serveur`, `@instagram_17841…:serveur`.
  let ghostPrefix: String
  /// `protocol.id` possibles dans l'event d'état `m.bridge`. mautrix y pose le
  /// `BeeperBridgeType` (`whatsappgo`, `instagramgo`) ; on accepte aussi le nom nu,
  /// que posaient les versions antérieures.
  let protocolIDs: Set<String>
  let loginFlow: LoginFlow
  /// Le réseau identifie-t-il les gens par un numéro de téléphone ? WhatsApp oui,
  /// Instagram non (un ID Meta à 17 chiffres n'est pas composable). Ce qui décide
  /// si un ghost peut fusionner avec un contact du carnet d'adresses.
  let identifiersArePhoneNumbers: Bool
  /// Suffixes que mautrix accole aux noms de ghosts (« Alice (WA) »).
  let displayNameSuffixes: [String]
  /// Le pont accepte-t-il `login phone <numéro>` en plus du QR ? WhatsApp oui,
  /// Signal non — mautrix-signal n'expose que le flow QR, et lui envoyer un
  /// `login phone` ne produirait qu'un message d'erreur du bot.
  let supportsPhonePairing: Bool
  /// Quitter le portail est-il relayé comme un départ du groupe côté réseau ?
  /// Vrai pour Signal et WhatsApp. Laissé faux pour Instagram tant que ce n'est
  /// pas vérifié : proposer le geste sans qu'il porte, c'est promettre un départ
  /// qui n'a pas lieu, et voir le salon renaître au message suivant.
  let relaysGroupLeave: Bool

  static let whatsapp = MatrixBridgeDescriptor(
    network: .whatsapp,
    botLocalpart: "whatsappbot",
    commandPrefix: "!wa",
    ghostPrefix: "whatsapp_",
    protocolIDs: ["whatsapp", "whatsappgo"],
    loginFlow: .qrCode,
    identifiersArePhoneNumbers: true,
    displayNameSuffixes: [" (WA)", " (WhatsApp)"],
    supportsPhonePairing: true,
    relaysGroupLeave: true
  )

  static let instagram = MatrixBridgeDescriptor(
    network: .instagram,
    botLocalpart: "instagrambot",
    commandPrefix: "!ig",
    ghostPrefix: "instagram_",
    protocolIDs: ["instagram", "instagramgo"],
    loginFlow: .webSession,
    identifiersArePhoneNumbers: false,
    // mautrix-instagram ne suffixe rien par défaut ; on nettoie quand même les
    // formes qu'on croise chez les instances qui l'ont configuré autrement.
    displayNameSuffixes: [" (IG)", " (Instagram)"],
    supportsPhonePairing: false,
    relaysGroupLeave: false
  )

  /// mautrix-signal se lie comme appareil secondaire, en scannant un QR depuis
  /// Réglages › Appareils liés. Le pont n'expose que ce flow : pas de code
  /// d'appairage, et l'enregistrement en appareil primaire n'existe plus.
  static let signal = MatrixBridgeDescriptor(
    network: .signal,
    botLocalpart: "signalbot",
    commandPrefix: "!signal",
    // Les ghosts portent l'UUID ACI du correspondant, pas son numéro.
    ghostPrefix: "signal_",
    // Ici `BeeperBridgeType` et `NetworkID` valent tous deux « signal » — pas de
    // forme en `-go` comme chez WhatsApp et Instagram.
    protocolIDs: ["signal"],
    loginFlow: .qrCode,
    // Signal se compose bien par E.164 (`pm +336…`), même si l'identité interne
    // est un UUID : `PhoneNormalizer` refuse les UUID, aucune fusion hasardeuse.
    identifiersArePhoneNumbers: true,
    displayNameSuffixes: [" (Signal)"],
    supportsPhonePairing: false,
    relaysGroupLeave: true
  )

  static let all: [MatrixBridgeDescriptor] = [.whatsapp, .instagram, .signal]

  static func descriptor(for network: MessageNetwork) -> MatrixBridgeDescriptor? {
    all.first { $0.network == network }
  }

  /// Réseau d'un bot de gestion, ou `nil` si ce MXID n'en est pas un.
  static func network(ofBot userID: String) -> MessageNetwork? {
    let local = MatrixIdentity.localpart(userID).lowercased()
    return all.first { $0.botLocalpart == local }?.network
  }

  /// Réseau d'un ghost, ou `nil` si ce MXID n'en est pas un.
  static func network(ofGhost userID: String) -> MessageNetwork? {
    let local = MatrixIdentity.localpart(userID).lowercased()
    return all.first { local.hasPrefix($0.ghostPrefix) }?.network
  }

  static func network(ofProtocol protocolID: String) -> MessageNetwork? {
    let needle = protocolID.lowercased()
    return all.first { $0.protocolIDs.contains(needle) }?.network
  }

  /// MXID complet du bot sur un homeserver donné.
  func botUserID(serverName: String) -> String { "@\(botLocalpart):\(serverName)" }

  /// Ce que l'app tape au bot pour ouvrir un fil vers un identifiant.
  ///
  /// `pm` est l'alias de `start-chat` dans bridgev2 : WhatsApp prend un numéro,
  /// Instagram l'identifiant numérique Meta (les pseudos passent d'abord par `search`).
  func startChatCommand(identifier: String) -> String { "pm \(identifier)" }
}

extension MessageNetwork {
  /// Descripteur du pont, ou `nil` pour un réseau natif (iMessage, Signal).
  var bridge: MatrixBridgeDescriptor? { MatrixBridgeDescriptor.descriptor(for: self) }
}
