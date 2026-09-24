import Foundation

/// Un contact tel que le pont le connaît du réseau lui-même — le carnet de
/// Signal, pas celui du Mac. C'est ce qui permet d'écrire à quelqu'un avec qui
/// on n'a encore aucun fil, comme depuis l'app Signal.
public struct BridgeContact: Sendable, Hashable, Identifiable {
  /// L'identifiant réseau (un UUID chez Signal) : ce qu'on donne à `create_dm`.
  public let id: String
  public let name: String
  /// Le numéro, quand le réseau le partage (`tel:+33…`) : il rapproche le
  /// contact d'une fiche du carnet ou d'un fil WhatsApp.
  public let phone: String?
  /// Le salon du tête-à-tête, s'il existe déjà.
  public let dmRoomID: String?

  public init(id: String, name: String, phone: String?, dmRoomID: String?) {
    self.id = id
    self.name = name
    self.phone = phone
    self.dmRoomID = dmRoomID
  }

  /// Lecture de `GET /_matrix/provision/v3/contacts`. Un contact sans nom
  /// n'est qu'un UUID : personne ne le reconnaîtrait dans une liste.
  public static func decodeList(_ data: Data) throws -> [BridgeContact] {
    struct Response: Decodable {
      struct Contact: Decodable {
        let id: String
        let name: String?
        let identifiers: [String]?
        let dmRoomID: String?
        enum CodingKeys: String, CodingKey {
          case id, name, identifiers
          case dmRoomID = "dm_room_mxid"
        }
      }
      let contacts: [Contact]?
    }
    let response = try JSONDecoder().decode(Response.self, from: data)
    return (response.contacts ?? []).compactMap { contact in
      let name = (contact.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !contact.id.isEmpty, !name.isEmpty else { return nil }
      let phone = contact.identifiers?.lazy
        .filter { $0.hasPrefix("tel:") }
        .map { String($0.dropFirst(4)) }
        .first
      return BridgeContact(id: contact.id, name: name, phone: phone, dmRoomID: contact.dmRoomID)
    }
  }
}

extension MatrixBridgeService {
  /// Les contacts du réseau, tels que le pont les tient (`/contacts`). Seul
  /// Signal est branché : ses identifiants sont des UUID qu'aucun carnet ne
  /// connaît, et sans cette liste on ne pouvait écrire qu'à un numéro.
  public func bridgeContacts(network: MessageNetwork) async throws -> [BridgeContact] {
    let data = try await provisioningRequest(network: network, method: "GET", path: "/contacts")
    return try BridgeContact.decodeList(data)
  }

  /// Ouvre (ou retrouve) le tête-à-tête avec un identifiant — UUID ou numéro
  /// au format international — et rend l'identifiant de conversation du salon.
  /// Le pont répond avec le salon : pas de bot à interroger, pas de réponse à
  /// relire dans un salon de gestion.
  public func createDirectChat(network: MessageNetwork, identifier: String) async throws -> String? {
    let escaped = identifier.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? identifier
    let data = try await provisioningRequest(network: network, path: "/create_dm/\(escaped)")
    struct Response: Decodable {
      let dmRoomID: String?
      enum CodingKeys: String, CodingKey { case dmRoomID = "dm_room_mxid" }
    }
    guard let roomID = try JSONDecoder().decode(Response.self, from: data).dmRoomID else { return nil }
    return "\(network.rawValue):\(roomID)"
  }
}
