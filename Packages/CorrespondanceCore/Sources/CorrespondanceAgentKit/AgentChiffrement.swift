import CorrespondanceMatrixClient
import Foundation

/// Comment `cc` gagne une machine crypto sans que l'AgentKit connaisse le Rust.
///
/// Le kit est du Foundation pur : il compile sous Linux, où l'XCFramework
/// d'Apple n'existe pas. On ne peut donc pas y importer
/// `CorrespondanceMatrixCrypto`. Mais l'exécutable, lui, le peut — quand le
/// drapeau de manifeste est levé. D'où cette **fermeture** : le kit déclare
/// l'endroit où le chiffrement se branche, l'exécutable fournit la pièce.
///
/// Elle est appelée une fois, juste après la connexion, parce que la machine
/// crypto a besoin du `device_id` que seul le `/login` donne. Elle rend une
/// ligne de journal, ou `nil` si rien n'a été branché.
public typealias AgentBranchementChiffrement =
  @Sendable (MatrixCredentials, MatrixClient) async -> String?

/// Où `cc` range ses clés : **sous son dossier d'amorce**, à côté de
/// `config.json` et `state.json`. Donc déplacé d'un bloc par
/// `CORRESPONDANCE_HOME`, comme le reste — un essai ne mélange jamais ses clés
/// avec celles du cc de production.
///
/// Perdre ce dossier, c'est perdre l'historique chiffré de cet appareil : c'est
/// exactement pour ça qu'il ne va pas dans un temporaire.
public enum AgentCryptoStore {
  public static func dossier(home: URL, userID: String, deviceID: String) -> URL {
    home
      .appendingPathComponent("crypto", isDirectory: true)
      .appendingPathComponent(nomDeFichier(userID) + "-" + nomDeFichier(deviceID), isDirectory: true)
  }

  static func nomDeFichier(_ valeur: String) -> String {
    String(valeur.map { $0.isLetter || $0.isNumber ? $0 : "_" })
  }
}
