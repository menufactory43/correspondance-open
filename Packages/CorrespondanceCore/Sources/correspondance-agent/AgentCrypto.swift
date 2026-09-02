import CorrespondanceAgentKit
import CorrespondanceMatrixClient
import Foundation

#if canImport(CorrespondanceMatrixCrypto)
  import CorrespondanceMatrixCrypto
#endif

/// Le chiffrement de bout en bout **du côté de `cc`**.
///
/// L'agent partage `MatrixClient` avec l'app : tout ce qui lui manquait, c'est
/// la machine crypto. Elle entre ici, dans l'exécutable, parce que
/// `CorrespondanceAgentKit` doit rester du Foundation pur — il compile sous
/// Linux, où l'XCFramework d'Apple n'existe pas.
///
/// **Un seul verrou, celui du manifeste.** Contrairement à la phase 2, il n'y a
/// pas de second verrou d'exécution : un `cc` construit avec la crypto lit et
/// écrit chiffré, point. `CORRESPONDANCE_CHIFFREMENT=0` reste possible pour
/// revenir en arrière sans reconstruire — c'est une soupape, pas un
/// interrupteur d'allumage.
enum AgentCrypto {

  /// Le chiffrement est-il dans ce binaire ?
  static var disponible: Bool {
    #if canImport(CorrespondanceMatrixCrypto)
      return true
    #else
      return false
    #endif
  }

  /// La soupape de secours. Absente ou différente de `0` : le chiffrement est actif.
  static var eteintParLEnvironnement: Bool {
    ProcessInfo.processInfo.environment["CORRESPONDANCE_CHIFFREMENT"] == "0"
  }

  /// La ligne que le journal doit porter au démarrage, dans tous les cas — y
  /// compris quand il n'y a pas de chiffrement. Un agent sourd doit le dire
  /// avant de le prouver par son silence.
  static func ligneDEtat() -> String {
    if !disponible {
      return "chiffrement : absent de ce binaire — je ne lirai pas les salons chiffrés"
    }
    if eteintParLEnvironnement {
      return "chiffrement : éteint par CORRESPONDANCE_CHIFFREMENT=0"
    }
    return "chiffrement : compilé"
  }

  /// La fermeture que l'`Agent` appelle après la connexion, ou `nil` s'il n'y a
  /// rien à brancher.
  static func branchement(home: URL) -> AgentBranchementChiffrement? {
    #if canImport(CorrespondanceMatrixCrypto)
      guard !eteintParLEnvironnement else { return nil }
      return { credentials, client in
        guard let deviceID = credentials.deviceID else {
          return "chiffrement refusé : le Relais n'a pas donné de device_id"
        }
        let dossier = AgentCryptoStore.dossier(
          home: home, userID: credentials.userID, deviceID: deviceID)
        do {
          let moteur = try RustCryptoEngine(
            userID: credentials.userID, deviceID: deviceID, dossier: dossier)
          await client.setCrypto(moteur)
          let cles = await moteur.clesDIdentite()
          return "chiffrement branché — appareil \(deviceID), ed25519 \(cles["ed25519"] ?? "?")"
            + " · magasin \(dossier.path())"
        } catch {
          return "chiffrement refusé : \(error)"
        }
      }
    #else
      _ = home
      return nil
    #endif
  }
}
