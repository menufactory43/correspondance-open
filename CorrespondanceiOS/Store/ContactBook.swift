import Contacts
import CorrespondanceCore
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

  /// Le nom qu'on a donné à ce numéro dans le carnet, s'il y est. C'est ce qui
  /// change « +33 6 12 34 56 78 » en « Julie » dans la liste des membres d'un
  /// groupe : le pont ne connaît que le numéro, le carnet connaît la personne.
  /// `nil` si le carnet est fermé, ou si personne ne porte ce numéro.
  func name(forPhone raw: String) async -> String? {
    guard let key = Self.phoneKey(raw) else { return nil }
    guard await ensureAccess() else { return nil }
    _ = loadIfNeeded()
    return byPhone[key]
  }

  /// Index numéro → nom, posé à la première lecture du carnet.
  private var byPhone: [String: String] = [:] {
    didSet { Self.snapshot.replace(byPhone) }
  }

  /// La même table, lisible sans attendre l'acteur : c'est ce que la liste de
  /// l'inbox consulte à chaque catalogue pour titrer un fil « Julie » plutôt
  /// que « +33 6… ». Vide tant que le carnet n'a pas été lu.
  private static let snapshot = NameSnapshot()

  nonisolated static func cachedName(forPhone raw: String) -> String? {
    guard let key = phoneKey(raw) else { return nil }
    return snapshot.name(for: key)
  }

  /// Lit le carnet si l'accès est déjà accordé — sans rien demander : au
  /// lancement, une boîte de permission tomberait sur un écran qui n'a rien
  /// demandé. La demande vient avec le premier geste qui en a besoin.
  func warm() async {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized, .limited: authorized = true
    default: return
    }
    _ = loadIfNeeded()
  }

  private final class NameSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    func replace(_ next: [String: String]) { lock.lock(); names = next; lock.unlock() }
    func name(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return names[key] }
  }

  /// Les neuf derniers chiffres : ce qui reste égal entre « +33 6… », « 06… »
  /// et le `whatsapp_336…` d'un fantôme de pont.
  nonisolated private static func phoneKey(_ raw: String) -> String? {
    let source = PhoneNormalizer.identityKey(for: raw).flatMap { key -> String? in
      key.hasPrefix("tel:") ? String(key.dropFirst(4)) : nil
    } ?? raw
    let digits = source.filter(\.isNumber)
    guard digits.count >= 9 else { return nil }
    return String(digits.suffix(9))
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
    var index: [String: String] = [:]
    for person in result {
      for phone in person.phones {
        if let key = Self.phoneKey(phone), index[key] == nil { index[key] = person.name }
      }
    }
    byPhone = index
    return result
  }
}
