import Foundation
import Security
import CorrespondanceMatrixClient

/// Le service réel, vu par les deux écrans.
///
/// Une coquille et non une conformité posée sur `MatrixBridgeService` : le
/// service est un acteur, le modèle est `@MainActor`, et c'est ici que la
/// frontière se traverse — une fois, explicitement.
public struct ChiffrementParLeRelais: ChiffrementDuCompte {
  private let service: MatrixBridgeService

  public init(_ service: MatrixBridgeService) { self.service = service }

  public func etat() async -> MatrixEtatChiffrement { await service.etatDuChiffrement() }
  public func versionDeSauvegarde() async -> String? { await service.versionDeSauvegardeDuRelais() }
  public func appareils() async -> [MatrixAppareilVu] { await service.appareilsAAfficher() }

  public func creerSauvegarde(phrase: String, remplacer: Bool) async throws -> Int {
    try await service.creerLaSauvegarde(phrase: phrase, remplacerLExistante: remplacer)
  }

  public func rejoindreSauvegarde(phrase: String) async throws -> MatrixImportDeCles {
    try await service.rejoindreLaSauvegarde(phrase: phrase)
  }

  public func deposerLesSignatures(phrase: String) async throws {
    try await service.deposerLesSignatures(phrase: phrase)
  }

  public func amorcerLesSignatures(motDePasse: String?) async throws {
    try await service.amorcerLesSignatures(motDePasse: motDePasse)
  }

  public func deconnecterAppareil(_ deviceID: String, motDePasse: String?) async throws
    -> MatrixDeconnexionAppareil
  {
    try await service.deconnecterAppareil(deviceID, motDePasse: motDePasse)
  }
}

/// La phrase gardée au Trousseau de **cet** appareil, pour que « Revoir » ne
/// soit pas un bouton qui ment.
///
/// Le service suit `CORRESPONDANCE_HOME`, comme la session Matrix et comme le
/// mot de passe des agents : un essai ne doit jamais retrouver la phrase du
/// vrai compte, ni l'écraser (c'est l'accident réparé dans `AgentSecretStore`).
public struct MagasinDePhraseAuTrousseau: MagasinDePhrase {
  private var service: String { "app.correspondance.phrase" + CorrespondanceHome.trialSuffix }

  public init() {}

  private func requete(_ compte: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: compte,
    ]
    if let group = MatrixCredentialStore.accessGroup { q[kSecAttrAccessGroup as String] = group }
    return q
  }

  public func lire(compte: String) -> String? {
    var r = requete(compte)
    r[kSecReturnData as String] = true
    r[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(r as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func ecrire(_ phrase: String, compte: String) {
    let data = Data(phrase.utf8)
    let base = requete(compte)
    if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      == errSecSuccess { return }
    var insert = base
    insert[kSecValueData as String] = data
    // `WhenUnlocked` et non `AfterFirstUnlock` : contrairement au mot de passe
    // d'un agent, cette phrase n'a jamais à être lue par un processus de fond.
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    SecItemAdd(insert as CFDictionary, nil)
  }

  public func effacer(compte: String) { SecItemDelete(requete(compte) as CFDictionary) }
}
