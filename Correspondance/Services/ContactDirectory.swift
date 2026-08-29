import AppKit
import Contacts
import Foundation

/// Annuaire Contacts macOS — noms + photos pour iMessage.
/// Cache disque pour démarrage instantané ; refresh Contacts en arrière-plan.
actor ContactDirectory {
  static let shared = ContactDirectory()

  private let store = CNContactStore()
  private var authorized: Bool?
  private var didIndex = false
  private var isRefreshing = false
  private var nameByKey: [String: String] = [:]
  /// Chemins relatifs sous `avatarsDirectory` (pas les Data en RAM pour tout l’annuaire).
  private var imagePathByKey: [String: String] = [:]

  struct ResolvedContact: Sendable {
    var name: String?
    var imageData: Data?
  }

  private nonisolated static var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private nonisolated static var indexURL: URL {
    supportDirectory.appendingPathComponent("contacts-index.json")
  }

  private nonisolated static var avatarsDirectory: URL {
    let dir = supportDirectory.appendingPathComponent("contact-avatars", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private struct DiskIndex: Codable {
    var names: [String: String]
    var imageFiles: [String: String]
    var savedAt: Date
  }

  init() {
    // Chargement sync du cache disque — prêt avant le 1er resolve.
    if let data = try? Data(contentsOf: Self.indexURL),
       let disk = try? JSONDecoder().decode(DiskIndex.self, from: data)
    {
      nameByKey = disk.names
      imagePathByKey = disk.imageFiles
    }
  }

  func resolve(handle: String) async -> ResolvedContact {
    let keys = lookupKeys(for: handle)
    var name: String?
    var image: Data?
    for key in keys {
      if name == nil { name = nameByKey[key] }
      if image == nil, let rel = imagePathByKey[key] {
        let url = Self.avatarsDirectory.appendingPathComponent(rel)
        image = try? Data(contentsOf: url)
      }
      if name != nil, image != nil { break }
    }

    // Si cache froid / incomplet → index Contacts (peut demander la permission).
    if name == nil || image == nil {
      await ensureIndex()
      for key in keys {
        if name == nil { name = nameByKey[key] }
        if image == nil, let rel = imagePathByKey[key] {
          let url = Self.avatarsDirectory.appendingPathComponent(rel)
          image = try? Data(contentsOf: url)
        }
      }
    } else {
      // Cache hit — refresh silencieux plus tard.
      Task { await self.refreshIndexIfNeeded() }
    }

    return ResolvedContact(name: name, imageData: image)
  }

  struct DirectoryHit: Identifiable, Hashable, Sendable {
    var name: String
    var handle: String
    var id: String { handle }
  }

  func searchPeople(query: String, limit: Int = 40) async -> [DirectoryHit] {
    await ensureIndex()
    let needle = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    var unique: [String: DirectoryHit] = [:]
    for (handle, name) in nameByKey {
      guard Self.isCanonicalHandle(handle) else { continue }
      if !needle.isEmpty {
        let hay = (name + " " + handle)
          .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard hay.contains(needle) else { continue }
      }
      if unique[handle] == nil {
        unique[handle] = DirectoryHit(name: name, handle: handle)
      }
    }
    return unique.values
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .prefix(limit)
      .map { $0 }
  }

  private static func isCanonicalHandle(_ handle: String) -> Bool {
    if handle.contains("@") { return handle.contains(".") }
    if handle.hasPrefix("+") { return handle.filter(\.isNumber).count >= 10 }
    let digits = handle.filter(\.isNumber)
    return digits.count >= 10 && handle.filter { !$0.isNumber && $0 != "+" && !$0.isWhitespace }.isEmpty
  }

  func displayName(forHandle handle: String) async -> String? {
    await resolve(handle: handle).name
  }

  func imageData(forHandle handle: String) async -> Data? {
    await resolve(handle: handle).imageData
  }

  /// Demande explicite l’accès Contacts (fait apparaître l’app dans Confidentialité).
  /// `force` ignore le cache mémoire pour pouvoir re-cliquer « Autoriser ».
  @discardableResult
  func requestAccessIfNeeded(force: Bool = false) async -> Bool {
    if force { authorized = nil }
    return await ensureAccess(allowPrompt: true)
  }

  nonisolated var authorizationStatus: CNAuthorizationStatus {
    CNContactStore.authorizationStatus(for: .contacts)
  }

  /// Enrichit les titres iMessage (1:1 + groupes sans vrai nom).
  func enrichIMessageTitles(_ conversations: inout [Conversation]) async {
    // Utilise d’abord le cache disque (instantané), puis complète via Contacts.
    await ensureIndex()

    for index in conversations.indices {
      guard conversations[index].network == .iMessage else { continue }
      var conversation = conversations[index]
      let handles = handles(for: conversation)

      if conversation.isGroup {
        if !conversation.hasPlaceholderTitle {
          conversations[index] = conversation
          continue
        }
        var names: [String] = []
        for handle in handles.prefix(4) {
          if let name = cachedName(for: handle) {
            names.append(name)
          } else if let name = await displayName(forHandle: handle) {
            names.append(name)
          } else {
            names.append(prettyHandle(handle))
          }
        }
        if !names.isEmpty {
          let suffix = handles.count > names.count ? "…" : ""
          conversation.preferTitle(names.joined(separator: ", ") + suffix)
        }
      } else if conversation.hasPlaceholderTitle {
        let peer = handles.first ?? conversation.address
        if let name = cachedName(for: peer) {
          conversation.preferTitle(name)
        } else if let name = await displayName(forHandle: peer) {
          conversation.preferTitle(name)
        }
      }

      conversations[index] = conversation
    }
  }



  func imageData(for conversation: Conversation) async -> Data? {
    guard conversation.network == .iMessage else { return nil }
    let handles = handles(for: conversation)
    for handle in handles.prefix(1) {
      // Cache disque d’abord (rapide).
      if let data = cachedImageData(for: handle) { return data }
      if let data = await imageData(forHandle: handle) { return data }
    }
    return nil
  }

  // MARK: - Cache helpers

  private func cachedName(for handle: String) -> String? {
    for key in lookupKeys(for: handle) {
      if let name = nameByKey[key] { return name }
    }
    return nil
  }

  private func cachedImageData(for handle: String) -> Data? {
    for key in lookupKeys(for: handle) {
      if let rel = imagePathByKey[key] {
        let url = Self.avatarsDirectory.appendingPathComponent(rel)
        if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
      }
    }
    return nil
  }

  // MARK: - Index

  private func ensureIndex() async {
    if didIndex { return }
    // On a peut-être déjà le cache disque — marque prêt et refresh async.
    if !nameByKey.isEmpty || !imagePathByKey.isEmpty {
      didIndex = true
      Task { await self.refreshIndexIfNeeded() }
      return
    }
    await rebuildIndexFromContacts()
    didIndex = true
  }

  private func refreshIndexIfNeeded() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    await rebuildIndexFromContacts()
  }

  private func rebuildIndexFromContacts() async {
    guard await ensureAccess() else { return }

    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactNicknameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactThumbnailImageDataKey as CNKeyDescriptor,
      CNContactImageDataKey as CNKeyDescriptor,
      CNContactImageDataAvailableKey as CNKeyDescriptor,
      CNContactIdentifierKey as CNKeyDescriptor,
    ]

    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true

    var nextNames: [String: String] = [:]
    var nextImages: [String: String] = [:]

    try? store.enumerateContacts(with: request) { contact, _ in
      let name = self.formattedName(contact)
      let image: Data? = {
        if let data = contact.thumbnailImageData, !data.isEmpty { return data }
        if contact.imageDataAvailable, let data = contact.imageData, !data.isEmpty { return data }
        return nil
      }()

      var imageFile: String?
      if let image {
        let file = self.sanitizeFilename(contact.identifier) + ".jpg"
        let url = Self.avatarsDirectory.appendingPathComponent(file)
        try? image.write(to: url, options: [.atomic])
        imageFile = file
      }

      for numbered in contact.phoneNumbers {
        let raw = numbered.value.stringValue
        for key in self.lookupKeys(for: raw) {
          if let name, nextNames[key] == nil { nextNames[key] = name }
          if let imageFile, nextImages[key] == nil { nextImages[key] = imageFile }
        }
      }

      for email in contact.emailAddresses {
        let raw = (email.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { continue }
        if let name, nextNames[raw] == nil { nextNames[raw] = name }
        if let imageFile, nextImages[raw] == nil { nextImages[raw] = imageFile }
      }
    }

    if !nextNames.isEmpty || !nextImages.isEmpty {
      nameByKey = nextNames
      imagePathByKey = nextImages
      persistIndex()
    }
    didIndex = true
  }

  private func persistIndex() {
    let disk = DiskIndex(names: nameByKey, imageFiles: imagePathByKey, savedAt: Date())
    guard let data = try? JSONEncoder().encode(disk) else { return }
    try? data.write(to: Self.indexURL, options: [.atomic])
  }

  private func sanitizeFilename(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }

  /// Clés de recherche robustes : e-mail, chiffres complets, derniers 8/9/10, variantes FR.
  private func lookupKeys(for handle: String) -> [String] {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    if trimmed.contains("@") {
      return [trimmed.lowercased()]
    }

    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return [trimmed.lowercased()] }

    var keys: Set<String> = [digits]
    for n in [8, 9, 10] where digits.count >= n {
      keys.insert(String(digits.suffix(n)))
    }
    if digits.hasPrefix("33"), digits.count >= 11 {
      let national = String(digits.dropFirst(2))
      keys.insert("0" + national)
      keys.insert(national)
      keys.insert(String(national.suffix(9)))
    }
    if digits.hasPrefix("0"), digits.count >= 10 {
      let national = String(digits.dropFirst())
      keys.insert("33" + national)
      keys.insert(national)
    }
    if digits.count == 9 {
      keys.insert("0" + digits)
      keys.insert("33" + digits)
    }
    return Array(keys)
  }

  private func handles(for conversation: Conversation) -> [String] {
    let parts = conversation.transportKey
      .split(separator: "|", omittingEmptySubsequences: false)
      .map(String.init)
    if parts.count >= 4 {
      let listed = parts[3]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !listed.isEmpty { return listed }
    }
    let address = conversation.address.trimmingCharacters(in: .whitespacesAndNewlines)
    if address.hasPrefix("chat") { return [] }
    return address.isEmpty ? [] : [address]
  }

  private func prettyHandle(_ handle: String) -> String {
    handle
  }

  private func formattedName(_ contact: CNContact) -> String? {
    if !contact.nickname.isEmpty { return contact.nickname }
    let person = [contact.givenName, contact.familyName]
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !person.isEmpty { return person }
    let org = contact.organizationName.trimmingCharacters(in: .whitespaces)
    return org.isEmpty ? nil : org
  }

  private func ensureAccess(allowPrompt: Bool = true) async -> Bool {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized:
      authorized = true
      return true
    case .restricted, .denied:
      authorized = false
      return false
    case .notDetermined:
      guard allowPrompt else { return false }
      let ok = await promptForAccessOnMainActor()
      authorized = ok
      return ok
    @unknown default:
      // `.limited` (macOS récents) : on tente la lecture.
      authorized = true
      return true
    }
  }

  private func promptForAccessOnMainActor() async -> Bool {
    await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
    try? await Task.sleep(for: .milliseconds(200))

    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      DispatchQueue.main.async {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
          cont.resume(returning: granted)
        }
      }
    }
  }
}
