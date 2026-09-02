import Foundation
import CorrespondanceMatrixClient
import MatrixSDKCrypto

/// La machine Olm/Megolm de matrix-rust-sdk, derrière la frontière du client.
///
/// Un `actor` parce que l'`OlmMachine` d'uniffi n'est pas `Sendable` : tout
/// passe par un seul fil, et le client Matrix — lui-même un acteur — l'appelle
/// en `await`.
///
/// Ce fichier n'existe que le drapeau `CORRESPONDANCE_CRYPTO=1` levé
/// (`Package.swift`) : sans lui, ni cette cible ni l'XCFramework ne sont
/// résolus, et `cc` continue de se construire sur Linux.
public actor RustCryptoEngine: MatrixCryptoEngine {
  let machine: OlmMachine
  private let dossier: URL
  /// La clé de sauvegarde dérivée de la phrase, gardée le temps de l'allumer et
  /// de la confier au magasin. Elle ne survit pas au processus : c'est le
  /// magasin qui la retient (`saveRecoveryKey`).
  var clesDeSauvegarde: BackupRecoveryKey?
  /// La version qu'on sauvegarde, quand on vient de l'allumer.
  var versionDeSauvegarde: String?
  public nonisolated let userID: String
  public nonisolated let deviceID: String

  /// - Parameters:
  ///   - dossier: où la machine persiste ses clés. **Sous le dossier de
  ///     l'app**, jamais dans un temporaire : perdre ce dossier, c'est perdre
  ///     l'historique chiffré de cet appareil.
  ///   - phrase: chiffre le magasin de clés au repos. `nil` = en clair sur le
  ///     disque (le magasin reste dans le bac à sable de l'app).
  public init(userID: String, deviceID: String, dossier: URL, phrase: String? = nil) throws {
    try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
    self.dossier = dossier
    self.userID = userID
    self.deviceID = deviceID
    self.machine = try OlmMachine(
      userId: userID, deviceId: deviceID, path: dossier.path, passphrase: phrase
    )
  }

  /// Le chemin conseillé : le dossier de l'app, une machine par session.
  /// Deux sessions du même compte ont deux `device_id` et donc deux magasins —
  /// c'est exactement ce que le partage de clés doit franchir.
  public static func dossierParDefaut(base: URL, userID: String, deviceID: String) -> URL {
    base
      .appendingPathComponent("crypto", isDirectory: true)
      .appendingPathComponent(Self.nomDeFichier(userID) + "-" + Self.nomDeFichier(deviceID), isDirectory: true)
  }

  static func nomDeFichier(_ valeur: String) -> String {
    String(valeur.map { $0.isLetter || $0.isNumber ? $0 : "_" })
  }

  // MARK: - MatrixCryptoEngine

  public func absorberSync(
    evenementsToDevice: [MatrixJSON],
    appareilsChanges: [String],
    appareilsPartis: [String],
    comptesCleUnique: [String: Int],
    clesDeSecoursInutilisees: [String]?,
    prochainLot: String
  ) async throws -> MatrixCryptoSyncResult {
    // La machine attend la **section `to_device` du /sync entière**
    // (`{"events":[…]}`), pas le tableau nu : un tableau lui fait rendre une
    // erreur de désérialisation, et la clé de salon n'est jamais extraite.
    let events = Self.texte(.object(["events": .array(evenementsToDevice)]))
    let resultat = try machine.receiveSyncChanges(
      events: events,
      deviceChanges: DeviceLists(changed: appareilsChanges, left: appareilsPartis),
      keyCounts: comptesCleUnique.mapValues { Int32($0) },
      unusedFallbackKeys: clesDeSecoursInutilisees,
      nextBatchToken: prochainLot,
      decryptionSettings: Self.reglagesDeLecture
    )
    return MatrixCryptoSyncResult(
      toDevice: resultat.toDeviceEvents,
      clesDeSalon: resultat.roomKeyInfos.map { "\($0.roomId) / \($0.sessionId)" }
    )
  }

  public func requetesSortantes() async throws -> [MatrixCryptoRequest] {
    try machine.outgoingRequests().map(Self.traduire)
  }

  public func marquerEnvoyee(id: String, genre: MatrixCryptoRequestKind, reponse: String) async throws {
    try machine.markRequestAsSent(requestId: id, requestType: Self.genre(genre), responseBody: reponse)
  }

  public func dechiffrer(evenementJSON: String, salon: String) async throws -> String {
    try machine.decryptRoomEvent(
      event: evenementJSON,
      roomId: salon,
      handleVerificationEvents: false,
      strictShields: false,
      decryptionSettings: Self.reglagesDeLecture
    ).clearEvent
  }

  public func chiffrer(salon: String, type: String, contenuJSON: String) async throws -> String {
    try machine.encrypt(roomId: salon, eventType: type, content: contenuJSON)
  }

  public func sessionsManquantes(membres: [String]) async throws -> MatrixCryptoRequest? {
    try machine.getMissingSessions(users: membres).map(Self.traduire)
  }

  public func partagerCleDeSalon(salon: String, membres: [String]) async throws -> [MatrixCryptoRequest] {
    try machine.shareRoomKey(roomId: salon, users: membres, settings: Self.reglagesDeSalon)
      .map(Self.traduire)
  }

  public func suivreUtilisateurs(_ utilisateurs: [String]) async throws {
    try machine.updateTrackedUsers(users: utilisateurs)
  }

  public func clesDIdentite() async -> [String: String] {
    machine.identityKeys()
  }

  /// Le journal de la machine Rust sur la sortie d'erreur — le seul endroit où
  /// un échec de déchiffrement Olm dit *pourquoi*. Réservé au banc de preuve.
  public static func journaliserSurStderr() {
    setLogger(logger: JournalDeLaMachine())
  }

  // MARK: - Les réglages, écrits une fois et expliqués

  /// **`.untrusted`** : on déchiffre ce qui arrive, même d'un appareil non
  /// vérifié. C'est le choix du spike, et il se défend : le Relais est privé,
  /// et refuser de lire ses propres messages parce qu'on n'a pas encore fait
  /// la vérification croisée rendrait l'inbox aveugle. Le chantier E complet
  /// remontera ce niveau **et** affichera l'écusson (`shieldState`) plutôt que
  /// de jeter le message.
  static let reglagesDeLecture = DecryptionSettings(senderDeviceTrustRequirement: .untrusted)

  /// **`.allDevices` / `onlyAllowTrustedDevices: false`** : la clé de salon
  /// part vers tous les appareils du compte, vérifiés ou non. C'est ce qui
  /// permet à une seconde session de lire sans cérémonie de vérification —
  /// voir la preuve B de `phase-2.md`. Le chantier E devra choisir entre ce
  /// confort et l'exclusion des appareils non signés (MSC4153).
  static let reglagesDeSalon = EncryptionSettings(
    algorithm: .megolmV1AesSha2,
    rotationPeriod: 604_800,          // une semaine
    rotationPeriodMsgs: 100,
    historyVisibility: .joined,
    onlyAllowTrustedDevices: false,
    errorOnVerifiedUserProblem: false
  )

  // MARK: - Traduction

  static func traduire(_ requete: Request) -> MatrixCryptoRequest {
    switch requete {
    case .toDevice(let id, let type, let body):
      return MatrixCryptoRequest(id: id, kind: .toDevice, eventType: type, body: body)
    case .keysUpload(let id, let body):
      return MatrixCryptoRequest(id: id, kind: .keysUpload, body: body)
    case .keysQuery(let id, let users):
      return MatrixCryptoRequest(id: id, kind: .keysQuery, users: users)
    case .keysClaim(let id, let oneTimeKeys):
      let corps = MatrixJSON.object([
        "one_time_keys": .object(oneTimeKeys.mapValues { appareils in
          MatrixJSON.object(appareils.mapValues { MatrixJSON.string($0) })
        })
      ])
      return MatrixCryptoRequest(id: id, kind: .keysClaim, body: Self.texte(corps))
    case .keysBackup(let id, _, let rooms):
      return MatrixCryptoRequest(id: id, kind: .keysBackup, body: rooms)
    case .roomMessage(let id, _, let type, let content):
      return MatrixCryptoRequest(id: id, kind: .roomMessage, eventType: type, body: content)
    case .signatureUpload(let id, let body):
      return MatrixCryptoRequest(id: id, kind: .signatureUpload, body: body)
    }
  }

  static func genre(_ kind: MatrixCryptoRequestKind) -> RequestType {
    switch kind {
    case .keysUpload: return .keysUpload
    case .keysQuery: return .keysQuery
    case .keysClaim: return .keysClaim
    case .toDevice: return .toDevice
    case .signatureUpload: return .signatureUpload
    case .keysBackup: return .keysBackup
    case .roomMessage: return .roomMessage
    }
  }

  static func texte(_ json: MatrixJSON) -> String {
    guard let data = try? JSONEncoder().encode(json) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
  }
}

/// Le récepteur du journal de la machine Rust.
final class JournalDeLaMachine: Logger, @unchecked Sendable {
  func log(logLine: String) {
    FileHandle.standardError.write(Data(("[crypto] " + logLine + "\n").utf8))
  }
}
