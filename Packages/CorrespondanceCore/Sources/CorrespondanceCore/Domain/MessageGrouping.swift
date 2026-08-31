import Foundation

/// Des messages consécutifs du même auteur, tels que le fil les montre : un
/// seul nom en tête, un seul horodatage, et des bulles serrées entre elles.
public struct MessageGroup: Identifiable, Equatable, Sendable {
  /// Identité du groupe : celle de son premier message, qui ne change plus.
  ///
  /// Stockée, pas calculée : `ForEach` redemande l'identifiant de chaque groupe
  /// à **chaque passe de placement** du `LazyVStack`, et lire `messages.first`
  /// y recopiait tout un `ChatMessage` — retains compris — des milliers de fois
  /// par seconde.
  public let id: String
  public var messages: [ChatMessage]
  /// Nom à écrire une fois, au-dessus du groupe. `nil` quand il n'y a rien à
  /// annoncer : un tête-à-tête, ou c'est moi qui parle.
  public var senderLabel: String?
  /// Horodatage à poser en séparateur AVANT le groupe. `nil` quand la
  /// conversation n'a pas assez respiré pour qu'on la redate.
  public var timeSeparator: Date?
  /// Réseau d'où viennent ces bulles. Un groupe n'en mêle jamais deux.
  public var network: MessageNetwork?
  /// Annoncer l'origine sur le séparateur (« 15:48 · iMessage »). Vrai au
  /// premier groupe d'un fil fusionné, et à chaque fois qu'on change de réseau.
  public var showsNetworkOrigin: Bool = false

  public var isFromMe: Bool { messages.first?.isFromMe ?? false }
  /// Le réseau à écrire dans le séparateur, s'il y a lieu de l'écrire.
  public var networkOrigin: MessageNetwork? { showsNetworkOrigin ? network : nil }

  public init(id: String, messages: [ChatMessage], senderLabel: String? = nil, timeSeparator: Date? = nil, network: MessageNetwork? = nil, showsNetworkOrigin: Bool = false) {
    self.id = id
    self.messages = messages
    self.senderLabel = senderLabel
    self.timeSeparator = timeSeparator
    self.network = network
    self.showsNetworkOrigin = showsNetworkOrigin
  }
}

/// Le découpage du fil en groupes — fonction pure, testée, sans SwiftUI.
///
/// Deux règles, celles de Messages : on change de groupe quand l'auteur change
/// ou quand la conversation s'est tue plus de cinq minutes ; on ne réaffiche
/// l'heure que sur ce silence-là (et au tout premier message). Répéter l'heure
/// sous chaque bulle, comme on le faisait, noie le fil sous les chiffres.
public enum MessageGrouping {
  /// Au-delà de ce silence, la conversation a changé de moment.
  public static let breakInterval: TimeInterval = 5 * 60

  /// - Parameter showsSenderNames: vrai en groupe, faux en tête-à-tête — où
  ///   nommer l'auteur à chaque prise de parole n'apprend rien.
  /// - Parameter showsNetworkOrigin: vrai sur un fil fusionné, où deux réseaux
  ///   se succèdent : le séparateur d'heure dit alors d'où vient la suite.
  public static func groups(
    for messages: [ChatMessage],
    showsSenderNames: Bool,
    showsNetworkOrigin: Bool = false
  ) -> [MessageGroup] {
    var groups: [MessageGroup] = []

    for message in messages {
      let previous = groups.last?.messages.last
      let silence = previous.map { message.sentAt.timeIntervalSince($0.sentAt) > breakInterval } ?? true
      let changedAuthor = previous.map {
        $0.isFromMe != message.isFromMe || authorKey($0) != authorKey(message)
      } ?? true
      // Deux réseaux ne se serrent jamais dans la même bulle : la même personne
      // sur iMessage et sur WhatsApp, ce sont deux prises de parole distinctes.
      let changedNetwork = previous.map { $0.network != message.network } ?? true

      // Un événement de conversation (« X a ajouté Y ») ne se groupe avec rien :
      // il s'écrit seul, en travers du fil, sans nom d'auteur au-dessus. Une
      // proposition de l'agent non plus : c'est une carte, pas une prise de parole.
      let isolated = message.isSystemEvent || previous?.isSystemEvent == true
        || message.isAgentProposal || previous?.isAgentProposal == true

      if silence || changedAuthor || isolated || changedNetwork {
        // On n'annonce l'origine qu'au premier groupe et aux bascules — pas à
        // chaque respiration à l'intérieur d'un même réseau.
        let marksOrigin = showsNetworkOrigin && changedNetwork
        groups.append(
          MessageGroup(
            id: message.id,
            messages: [message],
            senderLabel: showsSenderNames && !message.isFromMe && !message.isSystemEvent
              && !message.isAgentProposal
              ? label(for: message)
              : nil,
            timeSeparator: silence || marksOrigin ? message.sentAt : nil,
            network: message.network,
            showsNetworkOrigin: marksOrigin
          )
        )
      } else {
        groups[groups.count - 1].messages.append(message)
      }
    }

    return groups
  }

  /// Deux messages sont du même auteur si le réseau les attribue pareil.
  /// À défaut d'identifiant (iMessage sortant, message de service), le nom
  /// affiché fait foi.
  public static func authorKey(_ message: ChatMessage) -> String {
    if let id = message.senderID, !id.isEmpty { return id }
    return message.senderName ?? ""
  }

  /// Le nom lisible si le réseau l'a donné, l'identifiant sinon, rien du tout
  /// plutôt qu'un libellé vide.
  public static func label(for message: ChatMessage) -> String? {
    let name = (message.senderName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let identifier = (message.senderID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return identifier.isEmpty ? nil : identifier
  }
}
