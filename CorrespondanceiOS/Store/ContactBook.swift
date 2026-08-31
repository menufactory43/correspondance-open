import Contacts
import Foundation

/// Le carnet d'adresses de l'iPhone, pour écrire à quelqu'un qui n'est pas
/// encore sur le Relais : un nom qu'on connaît vaut mieux qu'un numéro qu'on
/// retape. Rien du Mac ici (`ContactDirectory`) — pas d'index disque, pas de
/// photos : la feuille « Nouvelle conversation » cherche, on répond.
actor ContactBook {
  static let shared = ContactBook()

  struct Person: Identifiable, Hashable, Sendable {
    var name: String
    /// Les numéros tels qu'écrits dans le carnet, un par identifiant réel.
    var phones: [String]
    var id: String { name + "|" + phones.joined(separator: ",") }
  }

  private let store = CNContactStore()
  private var authorized: Bool?
  private var cached: [Person]?

  /// La permission se demande au premier geste qui en a besoin — taper dans le
  /// champ — pas au lancement. Refusée, la section n'existe pas, sans bruit.
  func search(query: String, limit: Int = 20) async -> [Person] {
    let needle = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    guard !needle.isEmpty else { return [] }
    guard await ensureAccess() else { return [] }
    let everyone = loadIfNeeded()
    return Array(
      everyone
        .filter { person in
          (person.name + " " + person.phones.joined(separator: " "))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .contains(needle)
        }
        .prefix(limit)
    )
  }

  private func ensureAccess() async -> Bool {
    if let authorized { return authorized }
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized, .limited:
      authorized = true
    case .notDetermined:
      authorized = (try? await store.requestAccess(for: .contacts)) ?? false
    default:
      authorized = false
    }
    return authorized ?? false
  }

  private func loadIfNeeded() -> [Person] {
    if let cached { return cached }
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactNicknameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)
    // Les fiches liées (iCloud + Google…) fusionnent : une personne, une ligne.
    request.unifyResults = true
    request.sortOrder = .userDefault

    var result: [Person] = []
    try? store.enumerateContacts(with: request) { contact, _ in
      let name = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      let fallback = contact.nickname.isEmpty ? contact.organizationName : contact.nickname
      let displayed = name.isEmpty ? fallback : name
      guard !displayed.isEmpty else { return }

      var phones: [String] = []
      var digits: Set<String> = []
      for numbered in contact.phoneNumbers {
        let raw = numbered.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deux graphies d'un même numéro (+33 6… / 06…) sont le même identifiant.
        guard !raw.isEmpty, digits.insert(String(raw.filter(\.isNumber).suffix(9))).inserted
        else { continue }
        phones.append(raw)
      }
      guard !phones.isEmpty else { return }
      result.append(Person(name: displayed, phones: phones))
    }
    cached = result
    return result
  }
}
