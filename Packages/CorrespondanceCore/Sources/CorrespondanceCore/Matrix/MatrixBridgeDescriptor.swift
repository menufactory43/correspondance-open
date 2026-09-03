import Foundation

/// Ce qui distingue un pont mautrix d'un autre, en un seul endroit.
///
/// Sans ça, « whatsapp » finit écrit en dur dans le parseur, dans la reconnaissance des
/// ghosts, dans la commande envoyée au bot et dans trois vues. Ajouter Instagram voulait
/// alors dire retrouver toutes ces chaînes ; ici il suffit d'ajouter un descripteur.
public struct MatrixBridgeDescriptor: Sendable, Hashable {
  /// Comment on prouve son identité au réseau distant.
  public enum LoginFlow: Sendable, Hashable {
    /// Le bot poste un QR à scanner depuis le téléphone (WhatsApp).
    case qrCode
    /// L'utilisateur se connecte dans une fenêtre de navigation intégrée, et l'app
    /// transmet la session récoltée au bot (Instagram — Meta n'offre rien d'autre).
    case webSession
  }

  public let network: MessageNetwork
  /// Localpart du bot de gestion : `@whatsappbot:serveur`, `@instagrambot:serveur`.
  public let botLocalpart: String
  /// Préfixe des commandes, obligatoire hors salon de gestion (`!wa`, `!ig`).
  public let commandPrefix: String
  /// Préfixe des ghosts : `@whatsapp_lid-123:serveur`, `@instagram_17841…:serveur`.
  public let ghostPrefix: String
  /// `protocol.id` possibles dans l'event d'état `m.bridge`. mautrix y pose le
  /// `BeeperBridgeType` (`whatsappgo`, `instagramgo`) ; on accepte aussi le nom nu,
  /// que posaient les versions antérieures.
  public let protocolIDs: Set<String>
  public let loginFlow: LoginFlow
  /// Le réseau identifie-t-il les gens par un numéro de téléphone ? WhatsApp oui,
  /// Instagram non (un ID Meta à 17 chiffres n'est pas composable). Ce qui décide
  /// si un ghost peut fusionner avec un contact du carnet d'adresses.
  public let identifiersArePhoneNumbers: Bool
  /// Suffixes que mautrix accole aux noms de ghosts (« Alice (WA) »).
  public let displayNameSuffixes: [String]
  /// Le pont accepte-t-il `login phone <numéro>` en plus du QR ? WhatsApp oui,
  /// Signal non — mautrix-signal n'expose que le flow QR, et lui envoyer un
  /// `login phone` ne produirait qu'un message d'erreur du bot.
  public let supportsPhonePairing: Bool
  /// Identifiant du flow de connexion à nommer dans la commande `login`, quand le
  /// pont en expose plusieurs.
  ///
  /// bridgev2 ne choisit tout seul que si le connecteur n'a qu'un flow ; sinon il
  /// répond « Please specify a login flow » et n'ouvre rien. mautrix-facebook en
  /// annonce quatre (facebook.com, messenger.com, et les deux API Messenger Lite),
  /// et mautrix-instagram en a ajouté un second en amont. Nommer le flow coûte un
  /// mot et nous met à l'abri des deux côtés.
  public let webLoginFlowID: String?
  /// Quitter le portail est-il relayé comme un départ du groupe côté réseau ?
  /// Vrai pour Signal et WhatsApp. Laissé faux pour Instagram tant que ce n'est
  /// pas vérifié : proposer le geste sans qu'il porte, c'est promettre un départ
  /// qui n'a pas lieu, et voir le salon renaître au message suivant.
  public let relaysGroupLeave: Bool

  public static let whatsapp = MatrixBridgeDescriptor(
    network: .whatsapp,
    botLocalpart: "whatsappbot",
    commandPrefix: "!wa",
    ghostPrefix: "whatsapp_",
    protocolIDs: ["whatsapp", "whatsappgo"],
    loginFlow: .qrCode,
    identifiersArePhoneNumbers: true,
    displayNameSuffixes: [" (WA)", " (WhatsApp)"],
    supportsPhonePairing: true,
    webLoginFlowID: nil,
    relaysGroupLeave: true
  )

  public static let instagram = MatrixBridgeDescriptor(
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
    // Le flow par cookies de mautrix-instagram (l'autre, `instagram-password`, passe
    // par l'API mobile et n'est pas celui que la fenêtre de connexion alimente).
    webLoginFlowID: "instagram",
    relaysGroupLeave: false
  )

  /// Messenger : le jumeau d'Instagram côté Meta, mais un autre pont — mautrix-meta
  /// (l'image `v26.08` sans préfixe `ig-`), un autre bot, une autre base. Depuis
  /// v26.08 les deux réseaux ont chacun leur binaire, et donc chacun leur salon de
  /// gestion : rien ne se partage, pas même la session.
  public static let messenger = MatrixBridgeDescriptor(
    network: .messenger,
    botLocalpart: "messengerbot",
    // `!fb` est le préfixe par défaut du pont ; on le fige côté overrides pour que
    // l'app et lui parlent la même langue hors salon de gestion.
    commandPrefix: "!fb",
    ghostPrefix: "messenger_",
    // Le pont s'annonce en `facebook` (son `id` par défaut) ou `facebookgo`
    // (`BeeperBridgeType`). On accepte aussi `messenger` et `meta`, sous lesquels
    // d'autres déploiements le publient.
    protocolIDs: ["facebook", "facebookgo", "messenger", "meta"],
    loginFlow: .webSession,
    // Un compte Facebook s'identifie par un ID numérique, jamais par un numéro :
    // rien ne doit fusionner avec le carnet d'adresses sur cette base.
    identifiersArePhoneNumbers: false,
    displayNameSuffixes: [" (FB)", " (Messenger)"],
    supportsPhonePairing: false,
    // Quatre flows chez mautrix-facebook : cookies facebook.com, cookies
    // messenger.com, et deux API Messenger Lite par mot de passe. On prend
    // `facebook` : c'est sur facebook.com que la session du compte reste
    // joignable — messenger.com mure sa connexion derrière une 2FA qui échoue.
    webLoginFlowID: "facebook",
    // Même prudence que pour Instagram : tant que le départ d'un groupe n'a pas
    // été vu remonter jusqu'à Messenger, on ne propose pas le geste.
    relaysGroupLeave: false
  )

  /// X : les messages privés, par mautrix-twitter (v26.08, tag `v0.2608.0`).
  ///
  /// Le pont ne connaît que la session d'un navigateur — deux cookies de x.com,
  /// `auth_token` et `ct0` — d'où la même fenêtre de connexion que les réseaux
  /// Meta. Une étape de plus, propre à X : depuis que ses messages privés sont
  /// chiffrés (« X Chat »), le pont demande après les cookies le **code PIN à
  /// quatre chiffres** du compte, celui qui déverrouille les clés côté X. La
  /// feuille de connexion le sait et le demande (`BridgeLoginStep.awaitingPasscode`).
  ///
  /// Le connecteur annonce deux flows, `cookies` et `password` : on nomme le
  /// premier, sinon bridgev2 répond « Please specify a login flow ».
  public static let twitter = MatrixBridgeDescriptor(
    network: .twitter,
    botLocalpart: "twitterbot",
    commandPrefix: "!tw",
    // Les ghosts portent l'identifiant numérique du compte X (`@twitter_44196397`),
    // jamais le pseudo — qui peut changer.
    ghostPrefix: "twitter_",
    // `NetworkID` et `BeeperBridgeType` valent tous deux « twitter » chez ce
    // pont ; on accepte aussi « x », sous lequel un déploiement pourrait le publier.
    protocolIDs: ["twitter", "twittergo", "x"],
    loginFlow: .webSession,
    identifiersArePhoneNumbers: false,
    // `displayname_template` vaut « {{ .DisplayName }} (Twitter) » par défaut ;
    // notre gabarit de prod le passe en « (X) ». On nettoie les deux.
    displayNameSuffixes: [" (X)", " (Twitter)"],
    supportsPhonePairing: false,
    webLoginFlowID: "cookies",
    // Un groupe X quitté depuis le portail : pas vérifié sur un vrai compte,
    // même réserve que pour Meta.
    relaysGroupLeave: false
  )

  /// Slack : les espaces de travail, par mautrix-slack (v26.08, tag `v0.2608.0`).
  ///
  /// La session tient en deux morceaux, de deux endroits différents : le jeton
  /// `auth_token` (`xoxc-…`) vit dans le `localStorage` de la page (`localConfig_v2`),
  /// et le `cookie_token` (`xoxd-…`) est le cookie `d` de slack.com. D'où un type
  /// de session à part (`SlackLoginSession`) : ce n'est pas un pur jeu de cookies.
  ///
  /// Le connecteur annonce trois flows — `email`, `token`, `app`. On suit `email`
  /// par l'API de provisioning du pont (`provisioningPort`) : c'est la seule qui
  /// décrive le captcha que Slack exige avant d'envoyer le code. `token` reste le
  /// repli « coller la session ».
  public static let slack = MatrixBridgeDescriptor(
    network: .slack,
    botLocalpart: "slackbot",
    commandPrefix: "!slack",
    ghostPrefix: "slack_",
    protocolIDs: ["slack", "slackgo"],
    loginFlow: .webSession,
    identifiersArePhoneNumbers: false,
    displayNameSuffixes: [" (Slack)"],
    supportsPhonePairing: false,
    // Le flow natif : e-mail → code reçu par mail → espace de travail, piloté par
    // des saisies dans la fenêtre (comme Beeper). Le flow `token` (coller la
    // session) reste en repli, lancé à la demande.
    webLoginFlowID: "email",
    // Quitter un canal est relayé (le pont porte MemberActionLeave), mais on garde
    // la même prudence que les autres tant que ce n'est pas vu sur un vrai compte.
    relaysGroupLeave: false
  )

  /// mautrix-signal se lie comme appareil secondaire, en scannant un QR depuis
  /// Réglages › Appareils liés. Le pont n'expose que ce flow : pas de code
  /// d'appairage, et l'enregistrement en appareil primaire n'existe plus.
  public static let signal = MatrixBridgeDescriptor(
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
    webLoginFlowID: nil,
    relaysGroupLeave: true
  )

  public static let all: [MatrixBridgeDescriptor] = [.whatsapp, .instagram, .messenger, .twitter, .slack, .signal]

  /// Port de l'API de provisioning du pont (`/_matrix/provision/v3`), publié par
  /// docker-compose sur la même interface que Synapse (jamais 0.0.0.0). C'est le
  /// port `appservice.port` de chaque surcouche (`infra/matrix/templates`).
  ///
  /// L'app y lit les comptes connectés (`whoami`) et en déconnecte un
  /// (`logout/<id>`). Slack y suit aussi tout son flow de connexion : son captcha
  /// n'est décrit que là — un JavaScript à exécuter dans une vue web.
  public var provisioningPort: Int? {
    switch network {
    case .whatsapp: 29318
    case .signal: 29328
    case .instagram: 29330
    case .messenger: 29331
    case .twitter: 29332
    case .slack: 29335
    default: nil
    }
  }

  /// Le flow de connexion à suivre par l'API de provisioning plutôt que par le
  /// chat. Slack seulement : les autres ponts gardent le chat (QR posté dans le
  /// salon, session collée), qui marche et que les tests couvrent.
  public var provisionedLoginFlowID: String? {
    network == .slack ? webLoginFlowID : nil
  }

  /// Ce qu'est « un compte » sur ce réseau, et ce qu'il en est de plusieurs.
  /// bridgev2 accepte plusieurs connexions par utilisateur sur chaque pont ;
  /// c'est l'identité du compte qui change d'un réseau à l'autre.
  public var accountsHintFR: String {
    switch network {
    case .whatsapp, .signal: "Un compte par numéro. Plusieurs numéros possibles."
    case .slack: "Un compte par espace de travail. Plusieurs espaces possibles, même avec la même adresse."
    default: "Plusieurs comptes possibles."
    }
  }

  public static func descriptor(for network: MessageNetwork) -> MatrixBridgeDescriptor? {
    all.first { $0.network == network }
  }

  /// Réseau d'un bot de gestion, ou `nil` si ce MXID n'en est pas un.
  public static func network(ofBot userID: String) -> MessageNetwork? {
    let local = MatrixIdentity.localpart(userID).lowercased()
    return all.first { $0.botLocalpart == local }?.network
  }

  /// Réseau d'un ghost, ou `nil` si ce MXID n'en est pas un.
  public static func network(ofGhost userID: String) -> MessageNetwork? {
    let local = MatrixIdentity.localpart(userID).lowercased()
    return all.first { local.hasPrefix($0.ghostPrefix) }?.network
  }

  public static func network(ofProtocol protocolID: String) -> MessageNetwork? {
    let needle = protocolID.lowercased()
    return all.first { $0.protocolIDs.contains(needle) }?.network
  }

  /// MXID complet du bot sur un homeserver donné.
  public func botUserID(serverName: String) -> String { "@\(botLocalpart):\(serverName)" }

  /// Ce que l'app tape au bot pour ouvrir un fil vers un identifiant.
  ///
  /// `pm` est l'alias de `start-chat` dans bridgev2 : WhatsApp prend un numéro,
  /// Instagram et Messenger l'identifiant numérique Meta (les pseudos passent
  /// d'abord par `search`), X le pseudo tel quel — son connecteur le résout
  /// lui-même, et n'expose pas de `search`.
  public func startChatCommand(identifier: String) -> String { "pm \(identifier)" }

  public init(network: MessageNetwork, botLocalpart: String, commandPrefix: String, ghostPrefix: String, protocolIDs: Set<String>, loginFlow: LoginFlow, identifiersArePhoneNumbers: Bool, displayNameSuffixes: [String], supportsPhonePairing: Bool, webLoginFlowID: String? = nil, relaysGroupLeave: Bool) {
    self.network = network
    self.botLocalpart = botLocalpart
    self.commandPrefix = commandPrefix
    self.ghostPrefix = ghostPrefix
    self.protocolIDs = protocolIDs
    self.loginFlow = loginFlow
    self.identifiersArePhoneNumbers = identifiersArePhoneNumbers
    self.displayNameSuffixes = displayNameSuffixes
    self.supportsPhonePairing = supportsPhonePairing
    self.webLoginFlowID = webLoginFlowID
    self.relaysGroupLeave = relaysGroupLeave
  }
}

public extension MessageNetwork {
  /// Descripteur du pont, ou `nil` pour un réseau natif (iMessage, Signal).
  public var bridge: MatrixBridgeDescriptor? { MatrixBridgeDescriptor.descriptor(for: self) }
}
