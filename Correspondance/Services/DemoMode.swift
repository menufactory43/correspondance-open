import CorrespondanceCore
import Foundation

/// Le mode démonstration du Mac : aucune donnée réelle à l'écran, aucune
/// écriture chez l'utilisateur. Les fils bridgés sortent des fixtures `/sync`
/// de Core, passées au vrai service ; les fils iMessage sont inventés ici.
/// Sert aux captures d'écran et à travailler la mise en page.
///
/// Se déclenche par l'argument de lancement `-CorrespondanceDemo 1`. Le mode
/// et le thème se forcent par leurs clés de préférences sur la même ligne de
/// commande (`-correspondance.inboxMode focus -correspondance.theme encreDeNuit`) :
/// le domaine des arguments prime sans rien écrire.
/// Cf. `scripts/demo-mac.sh`. Jamais en production.
enum DemoMode {
  static let launchArgument = "-CorrespondanceDemo"

  static var isRequested: Bool { CommandLine.arguments.contains(launchArgument) }

  /// Le fil à ouvrir d'emblée, par son titre (`-CorrespondanceDemoSelect "Vacances 2026"`).
  static var requestedSelection: String? {
    guard isRequested else { return nil }
    return UserDefaults.standard.string(forKey: "CorrespondanceDemoSelect")
  }

  static let selfUserID = DemoFixtures.selfUserID

  // MARK: - iMessage inventé

  private static let camille = "imessage:demo-camille"
  private static let papa = "imessage:demo-papa"
  private static let rando = "imessage:demo-rando"
  private static let theo = "imessage:demo-theo"

  static func iMessageConversations(now: Date = .now) -> [Conversation] {
    [
      Conversation(
        id: camille, network: .iMessage, address: "+33600000011", title: "Camille",
        preview: "On dit 19 h 30 devant le cinéma ?", lastMessageAt: now.addingTimeInterval(-6 * 60),
        unreadCount: 2, isArchived: false, transportKey: "demo", isGroup: false
      ),
      Conversation(
        id: rando, network: .iMessage, address: "rando", title: "Rando dimanche",
        preview: "Nadia : Je prends les sandwichs 🥪", lastMessageAt: now.addingTimeInterval(-52 * 60),
        unreadCount: 5, isArchived: false, transportKey: "demo", isGroup: true,
        participantHandles: ["+33600000021", "+33600000022", "+33600000023"]
      ),
      Conversation(
        id: papa, network: .iMessage, address: "+33600000012", title: "Papa",
        preview: "Bien reçu, merci mon grand.", lastMessageAt: now.addingTimeInterval(-3 * 3600),
        unreadCount: 0, isArchived: false, transportKey: "demo", isGroup: false,
        lastDelivery: .read, lastMessageIsFromMe: false
      ),
      Conversation(
        id: theo, network: .iMessage, address: "+33600000013", title: "Théo",
        preview: "Je t'envoie le lien ce soir", lastMessageAt: now.addingTimeInterval(-26 * 3600),
        unreadCount: 0, isArchived: false, transportKey: "demo", isGroup: false,
        lastDelivery: .delivered, lastMessageIsFromMe: true
      ),
    ]
  }

  static func iMessageMessages(now: Date = .now) -> [String: [ChatMessage]] {
    func m(_ id: String, _ conversation: String, _ text: String, _ minutesAgo: Double, me: Bool,
           sender: String? = nil, reactions: [MessageReaction] = []) -> ChatMessage {
      ChatMessage(
        id: "demo-\(id)", conversationID: conversation, network: .iMessage, text: text,
        sentAt: now.addingTimeInterval(-minutesAgo * 60), isFromMe: me,
        senderName: me ? nil : sender, reactions: reactions
      )
    }
    return [
      camille: [
        m("c1", camille, "Tu as vu la bande-annonce du film de jeudi ?", 95, me: false, sender: "Camille"),
        m("c2", camille, "Oui ! Ça a l'air très bien. On y va ?", 88, me: true),
        m("c3", camille, "Carrément.", 40, me: false, sender: "Camille",
          reactions: [MessageReaction(emoji: "❤️", senders: ["Moi"], isMine: true)]),
        m("c4", camille, "On dit 19 h 30 devant le cinéma ?", 6, me: false, sender: "Camille"),
      ],
      rando: [
        m("r1", rando, "Dimanche, départ 8 h du parking de la gare ?", 180, me: false, sender: "Nadia"),
        m("r2", rando, "Ok pour moi. Il y a un point d'eau sur le chemin ?", 170, me: true),
        m("r3", rando, "Oui, à mi-parcours. Prenez quand même 1,5 L.", 160, me: false, sender: "Louis"),
        m("r4", rando, "Je m'occupe des fruits 🍎", 90, me: false, sender: "Inès"),
        m("r5", rando, "Je prends les sandwichs 🥪", 52, me: false, sender: "Nadia",
          reactions: [MessageReaction(emoji: "👍", senders: ["Louis", "Inès"])]),
      ],
      papa: [
        m("p1", papa, "Je t'ai envoyé les photos du jardin, tu me diras.", 250, me: false, sender: "Papa"),
        m("p2", papa, "Elles sont superbes. Le cerisier a bien pris !", 200, me: true),
        m("p3", papa, "Bien reçu, merci mon grand.", 180, me: false, sender: "Papa"),
      ],
      theo: [
        m("t1", theo, "Tu avais parlé d'un article sur les fontes variables ?", 1600, me: false, sender: "Théo"),
        m("t2", theo, "Je t'envoie le lien ce soir", 1560, me: true),
      ],
    ]
  }
}
