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
/// 2. ~~La variable d'exécution `CORRESPONDANCE_CHIFFREMENT=1`~~ — **levé en
///    phase 5.** Elle existait parce que le chantier E était commencé et pas
///    fini : on voulait un binaire capable de chiffrer qui se comporte quand
///    même comme avant. Maintenant que la sauvegarde des clés, la vérification
///    d'appareil et `cc` sont là, demander en plus une variable d'environnement
///    reviendrait à livrer une app dont le chiffrement est éteint chez tout le
///    monde. **Un binaire construit avec la crypto chiffre.**
///
///    `CORRESPONDANCE_CHIFFREMENT=0` reste lu : c'est la soupape pour revenir
///    au comportement d'avant sans reconstruire, pas un interrupteur
///    d'allumage. Même règle que pour `cc` (`AgentCrypto`).
///
/// Le drapeau de manifeste, lui, **reste** : `matrix-sdk-crypto-ffi` n'est
/// publié qu'en XCFramework Apple, et `cc` se construit aussi pour Linux, où
/// la bibliothèque n'existe pas encore (cf. `docs/spike-un-clic/phase-5.md`).
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

  /// Est-il actif pour cette exécution ? Oui dès qu'il est compilé — sauf
  /// soupape explicite.
  public static var demande: Bool {
    disponible && ProcessInfo.processInfo.environment[variable] != "0"
  }

  /// La soupape, pour le dire à l'écran plutôt que de laisser deviner.
  public static var eteintParLEnvironnement: Bool {
    disponible && ProcessInfo.processInfo.environment[variable] == "0"
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
