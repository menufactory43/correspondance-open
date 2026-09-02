import CorrespondanceMatrixClient
import Foundation

// AES-GCM et HKDF, pour le coffre qui porte les clés de signature. CryptoKit
// sur Apple ; swift-crypto sous Linux, où CryptoKit n'existe pas — c'est la
// **même** implémentation BoringSSL derrière la même API, donc un coffre
// scellé sur le Mac s'ouvre sur le Linux, ce qui est tout l'enjeu.
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import MatrixSDKCrypto

/// La sauvegarde des clés et la vérification d'appareil, côté machine Rust.
///
/// Rien ici ne fait de réseau : chaque méthode rend de la matière que
/// `MatrixClient` postera. C'est la même règle que pour le déchiffrement, et
/// c'est ce qui permet de tout éprouver sans serveur.
extension RustCryptoEngine: MatrixCryptoSauvegarde {

  // MARK: - Sauvegarde des clés

  public func cleDeSauvegarde(phrase: String, sel: String?, tours: Int32?) async throws
    -> MatrixCleDeSauvegarde
  {
    // Sans sel : la machine en tire un au hasard, et c'est celui-là qu'il faut
    // publier. Avec sel : on **redérive** exactement la même clé — c'est ce que
    // fait un appareil neuf qui n'a que la phrase.
    let cle: BackupRecoveryKey
    if let sel, let tours {
      cle = BackupRecoveryKey.fromPassphrase(passphrase: phrase, salt: sel, rounds: tours)
    } else {
      cle = BackupRecoveryKey.newFromPassphrase(passphrase: phrase)
    }
    clesDeSauvegarde = cle
    let publique = cle.megolmV1PublicKey()
    return MatrixCleDeSauvegarde(
      clePublique: publique.publicKey,
      signatures: publique.signatures,
      sel: publique.passphraseInfo?.privateKeySalt ?? sel,
      tours: publique.passphraseInfo?.privateKeyIterations ?? tours
    )
  }

  public func activerSauvegarde(_ cle: MatrixCleDeSauvegarde, version: String) async throws {
    guard let privee = clesDeSauvegarde else {
      throw MatrixCryptoErreur.pasDeCleDeSauvegarde
    }
    // Éteindre d'abord : une machine qui a connu une version antérieure garde
    // des requêtes en attente pour elle, et le Relais refuse d'écrire ailleurs
    // que dans la dernière version — « You may only manipulate the most
    // recently created version ».
    try? machine.disableBackup()
    try machine.enableBackupV1(key: privee.megolmV1PublicKey(), version: version)
    versionDeSauvegarde = version
  }

  public func retenirCleDeRecuperation(_ cle: MatrixCleDeSauvegarde, version: String) async throws {
    guard let privee = clesDeSauvegarde else {
      throw MatrixCryptoErreur.pasDeCleDeSauvegarde
    }
    try machine.saveRecoveryKey(key: privee, version: version)
  }

  public func requeteDeSauvegarde() async throws -> MatrixCryptoRequest? {
    // `backupRoomKeys` rend une fournée à la fois, et `nil` quand tout est
    // sauvegardé : c'est la boucle d'arrêt de `sauvegarderLesCles`.
    guard let requete = try machine.backupRoomKeys() else { return nil }
    guard case .keysBackup(let id, let version, let rooms) = requete else {
      return Self.traduire(requete)
    }
    return MatrixCryptoRequest(id: id, kind: .keysBackup, body: rooms, version: version)
  }

  public func importerDepuisSauvegarde(clesJSON: String, version: String) async throws
    -> MatrixImportDeCles
  {
    // **Le déchiffrement est à notre charge.** `importRoomKeysFromBackup` dit
    // dans sa documentation « the decryption step is skipped and should be
    // performed by the caller » : ce qu'il attend, ce n'est pas la réponse du
    // serveur mais **un tableau de clés en clair**, du même format que
    // `exportRoomKeys`. Passer la réponse telle quelle donne
    // `invalid type: map, expected a sequence` — une erreur qui ne dit pas
    // qu'il manque une étape entière.
    guard let privee = clesDeSauvegarde else { throw MatrixCryptoErreur.pasDeCleDeSauvegarde }
    let racine = try JSONSerialization.jsonObject(with: Data(clesJSON.utf8)) as? [String: Any]
    let salons = racine?["rooms"] as? [String: Any] ?? [:]
    var exportees: [[String: Any]] = []
    var total = 0
    for (salonID, contenu) in salons {
      let sessions = (contenu as? [String: Any])?["sessions"] as? [String: Any] ?? [:]
      for (sessionID, brute) in sessions {
        total += 1
        guard let brute = brute as? [String: Any],
              let donnees = brute["session_data"] as? [String: Any],
              let ephemere = donnees["ephemeral"] as? String,
              let mac = donnees["mac"] as? String,
              let chiffre = donnees["ciphertext"] as? String
        else { continue }
        guard let clair = try? privee.decryptV1(
          ephemeralKey: ephemere, mac: mac, ciphertext: chiffre),
          var cle = try? JSONSerialization.jsonObject(with: Data(clair.utf8)) as? [String: Any]
        else { continue }
        // La clé sauvegardée ne porte ni son salon ni son identifiant de
        // session : c'est la carte qui les portait.
        cle["room_id"] = salonID
        cle["session_id"] = sessionID
        exportees.append(cle)
      }
    }
    let tableau = try JSONSerialization.data(withJSONObject: exportees)
    let resultat = try machine.importRoomKeysFromBackup(
      keys: String(data: tableau, encoding: .utf8) ?? "[]",
      backupVersion: version, progressListener: ProgresMuet())
    return MatrixImportDeCles(importees: Int(resultat.imported), total: max(total, Int(resultat.total)))
  }

  public func sauvegardeActive() async -> Bool { machine.backupEnabled() }

  public func versionSauvegardee() async -> String? {
    if let version = versionDeSauvegarde { return version }
    return (try? machine.getBackupKeys())??.backupVersion()
  }

  // MARK: - Vérification d'appareil

  public func amorcerSignaturesCroisees() async throws -> MatrixAmorceSignatures {
    let resultat = try machine.bootstrapCrossSigning()
    var requetes: [MatrixCryptoRequest] = []
    if let upload = resultat.uploadKeysRequest { requetes.append(Self.traduire(upload)) }
    // La signature de notre propre appareil par la clé self-signing toute
    // neuve : sans elle, l'appareil qui vient de créer les clés se verrait
    // lui-même « non vérifié ».
    requetes.append(
      MatrixCryptoRequest(
        id: UUID().uuidString, kind: .signatureUpload,
        body: resultat.uploadSignatureRequest.body))
    return MatrixAmorceSignatures(
      cleMaitresse: resultat.uploadSigningKeysRequest.masterKey,
      cleSelfSigning: resultat.uploadSigningKeysRequest.selfSigningKey,
      cleUserSigning: resultat.uploadSigningKeysRequest.userSigningKey,
      requetes: requetes
    )
  }

  public func etatDesSignatures() async -> MatrixEtatSignatures {
    let etat = machine.crossSigningStatus()
    return MatrixEtatSignatures(
      maitresse: etat.hasMaster, selfSigning: etat.hasSelfSigning,
      userSigning: etat.hasUserSigning)
  }

  public func verifierAppareil(userID: String, deviceID: String) async throws
    -> MatrixCryptoRequest
  {
    let requete = try machine.verifyDevice(userId: userID, deviceId: deviceID)
    return MatrixCryptoRequest(
      id: UUID().uuidString, kind: .signatureUpload, body: requete.body)
  }

  public func appareils(de userID: String) async throws -> [MatrixAppareil] {
    try machine.getUserDevices(userId: userID, timeout: 10).map { appareil in
      MatrixAppareil(
        deviceID: appareil.deviceId,
        nom: appareil.displayName,
        clesEd25519: appareil.keys["ed25519:\(appareil.deviceId)"] ?? appareil.keys["ed25519"],
        verifieParSignature: appareil.crossSigningTrusted,
        deConfianceLocalement: appareil.locallyTrusted,
        estMoi: appareil.deviceId == deviceID
      )
    }
  }

  public func exporterClesDeSignature() async throws -> MatrixExportSignatures? {
    guard let export = try machine.exportCrossSigningKeys() else { return nil }
    return MatrixExportSignatures(
      maitresse: export.masterKey, selfSigning: export.selfSigningKey,
      userSigning: export.userSigningKey)
  }

  public func importerClesDeSignature(_ export: MatrixExportSignatures) async throws {
    try machine.importCrossSigningKeys(
      export: CrossSigningKeyExport(
        masterKey: export.maitresse, selfSigningKey: export.selfSigning,
        userSigningKey: export.userSigning))
  }
}

// MARK: - Le coffre

extension RustCryptoEngine {

  /// La clé qui scelle le coffre, dérivée de la **même** phrase et du **même**
  /// sel que la sauvegarde des clés.
  ///
  /// Deux précautions qui n'ont l'air de rien : on passe par la dérivation
  /// PBKDF de la machine Rust (donc une seule implémentation, déjà éprouvée),
  /// puis on **re-dérive** par HKDF avec un `info` qui nomme l'usage. Se servir
  /// directement de la clé de sauvegarde pour chiffrer autre chose, ce serait
  /// employer un même secret à deux fins — la faute classique.
  static func cleDuCoffre(phrase: String, sel: String, tours: Int32) -> SymmetricKey {
    let recuperation = BackupRecoveryKey.fromPassphrase(
      passphrase: phrase, salt: sel, rounds: tours)
    let graine = Data(base64Encoded: recuperation.toBase64()) ?? Data(recuperation.toBase64().utf8)
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: graine),
      info: Data("fr.correspondance.coffre.v1".utf8),
      outputByteCount: 32)
  }

  public func sceller(_ clair: Data, phrase: String, sel: String, tours: Int32) async throws -> Data
  {
    let boite = try AES.GCM.seal(clair, using: Self.cleDuCoffre(phrase: phrase, sel: sel, tours: tours))
    guard let combine = boite.combined else {
      throw MatrixCryptoErreur.coffreIllisible
    }
    return combine
  }

  public func desceller(_ scelle: Data, phrase: String, sel: String, tours: Int32) async throws
    -> Data
  {
    do {
      let boite = try AES.GCM.SealedBox(combined: scelle)
      return try AES.GCM.open(
        boite, using: Self.cleDuCoffre(phrase: phrase, sel: sel, tours: tours))
    } catch {
      // Une phrase fausse et un coffre abîmé donnent la même erreur du côté
      // d'AES-GCM. On dit la cause probable plutôt que « authentication failure ».
      throw MatrixCryptoErreur.coffreIllisible
    }
  }
}

public enum MatrixCryptoErreur: Error, LocalizedError {
  case coffreIllisible
  case pasDeCleDeSauvegarde

  public var errorDescription: String? {
    switch self {
    case .pasDeCleDeSauvegarde:
      "Aucune clé de sauvegarde en mémoire : il faut d'abord la dériver de la phrase."
    case .coffreIllisible:
      "Le coffre ne s'ouvre pas avec cette phrase."
    }
  }
}

/// La barre de progression de l'import. On n'en affiche pas : l'import d'un
/// magasin de spike tient en une seconde, et une barre qui ment est pire qu'une
/// barre absente.
final class ProgresMuet: ProgressListener, @unchecked Sendable {
  func onProgress(progress: Int32, total: Int32) {}
}
