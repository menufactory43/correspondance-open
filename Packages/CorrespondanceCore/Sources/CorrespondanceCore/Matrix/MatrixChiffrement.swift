import Foundation
import CorrespondanceMatrixClient

#if canImport(CorrespondanceMatrixCrypto)
  import CorrespondanceMatrixCrypto
#endif

/// Le chiffrement de bout en bout, tel que l'app peut l'allumer aujourd'hui.
///
/// **Deux verrous, tous deux fermés par défaut.**
///
/// 1. Le drapeau du manifeste `CORRESPONDANCE_CRYPTO=1` : sans lui, la cible
///    `CorrespondanceMatrixCrypto` n'existe pas, l'XCFramework n'est pas
///    téléchargé, et `#if canImport` ci-dessous efface tout ce fichier. La cible
///    Mac de production et `cc` (qui vit sous Linux, où l'XCFramework n'existe
///    pas) se construisent exactement comme avant.
/// 2. La variable d'exécution `CORRESPONDANCE_CHIFFREMENT=1` : même construite
///    avec le drapeau, l'app ne branche la machine crypto que si on le lui
///    demande. Un binaire, deux comportements, et le comportement d'avant reste
///    celui par défaut.
///
/// Tant que le chantier E n'est pas fini (sauvegarde des clés avec phrase,
/// vérification d'appareil, partage avec `cc` et l'extension iOS), c'est le
/// contrat : le chiffrement s'éprouve, il ne s'impose pas.
public enum MatrixChiffrement {

  /// La variable d'exécution qui lève le second verrou.
  public static let variable = "CORRESPONDANCE_CHIFFREMENT"

  /// Le chiffrement est-il compilé dans ce binaire ?
  public static var disponible: Bool {
    #if canImport(CorrespondanceMatrixCrypto)
      return true
    #else
      return false
    #endif
  }

  /// Est-il demandé pour cette exécution ?
  public static var demande: Bool {
    ProcessInfo.processInfo.environment[variable] == "1"
  }

  /// Où le magasin de clés vit : **dans le dossier de données de l'app**, donc
  /// déplacé d'un bloc par `CORRESPONDANCE_HOME` — un essai ne mélange jamais
  /// ses clés avec celles des vraies conversations.
  public static func dossier(userID: String, deviceID: String) -> URL {
    #if canImport(CorrespondanceMatrixCrypto)
      return RustCryptoEngine.dossierParDefaut(
        base: CorrespondanceHome.directory(), userID: userID, deviceID: deviceID
      )
    #else
      return CorrespondanceHome.directory().appendingPathComponent("crypto", isDirectory: true)
    #endif
  }

  /// Branche la machine crypto sur un client, si les deux verrous sont ouverts.
  /// Rend une ligne pour le journal, ou `nil` si rien n'a été branché.
  @discardableResult
  public static func brancher(sur client: MatrixClient) async -> String? {
    #if canImport(CorrespondanceMatrixCrypto)
      guard demande else { return nil }
      guard await !client.chiffrementActif else { return nil }
      guard let creds = await client.currentCredentials, let deviceID = creds.deviceID else {
        return nil
      }
      do {
        let moteur = try RustCryptoEngine(
          userID: creds.userID, deviceID: deviceID,
          dossier: dossier(userID: creds.userID, deviceID: deviceID)
        )
        await client.setCrypto(moteur)
        let cles = await moteur.clesDIdentite()
        return "chiffrement branché — appareil \(deviceID), ed25519 \(cles["ed25519"] ?? "?")"
      } catch {
        return "chiffrement refusé : \(error)"
      }
    #else
      _ = client
      return nil
    #endif
  }
}
