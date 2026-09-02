import Foundation

// MARK: - macOS seulement, et ce n'est pas un oubli
//
// Deux murs, tous deux découverts en construisant la cible iOS, et tous deux
// définitifs pour cette approche-ci :
//
//   1. **`Process` n'existe pas sur iOS.** Une app iPhone ne lance pas de
//      processus enfant : `Foundation` n'expose même pas le type. Le modèle
//      « l'app lance `tailcat socks` à côté d'elle » n'a donc pas d'équivalent.
//      Il faudrait embarquer tailcat **dans** le binaire — c'est du Go, donc
//      `gomobile bind` vers un XCFramework, ce qui ajoute le runtime Go au
//      bundle : compter 10 à 15 Mio par tranche, sur les 22 Mio compressés
//      qu'ajoute déjà la machine crypto.
//   2. **`kCFNetworkProxiesSOCKS*` est marqué indisponible sur iOS.** CFNetwork
//      n'y offre pas de mandataire SOCKS ; poser les clés en chaînes brutes
//      compilerait et ne ferait rien, ce qui est pire. Un tailcat embarqué
//      devrait donc exposer un `URLProtocol` ou une socket locale, pas un
//      SOCKS que le système sait utiliser.
//
// D'où la garde : sur iOS, ce fichier n'existe pas, et l'app y joint le Relais
// comme avant. Écrit ici plutôt que dans une note, parce que c'est le compilateur
// qui l'a appris.
#if os(macOS)

/// Le mandataire SOCKS que `tailcat` ouvre pour joindre le Relais **sans
/// tunnel ssh et sans Tailscale**.
///
/// **Ce que ça remplace.** Aujourd'hui, un Relais posé sur une machine à soi
/// n'écoute que sur `127.0.0.1` — c'est ce qu'il faut : un Synapse ouvert sur
/// l'Internet est une porte. Le joindre depuis un autre poste demandait donc
/// soit Tailscale (un compte, un tailnet, une extension système sur le Mac,
/// et rien du tout sur un iPhone qui ne l'a pas), soit `ssh -N -L` (un
/// terminal, une clé, et une commande que personne ne retape).
///
/// Tailcat prend le plan de données de Tailscale — WireGuard, traversée de
/// NAT, relais DERP en repli — **sans son plan de contrôle** : pas de compte,
/// pas de tailnet, pas de démon privilégié. Le Relais publie un « addrblob »
/// d'une centaine d'octets, le code d'appairage le porte, et l'app ouvre un
/// SOCKS5 local par lequel passe tout son trafic Matrix.
///
/// **Ce que ça ne fait pas.** Tailcat n'authentifie personne par défaut : qui
/// détient l'addrblob joint le Relais. C'est exactement le même régime que le
/// mot de passe que le code d'appairage porte déjà — donc pas une régression —
/// mais ça veut dire qu'un code d'appairage devient une clé de réseau en plus
/// d'être une clé de compte. Il périme toujours en quinze minutes.
@MainActor
public final class TailcatProxy {

  /// Où le binaire vit. L'installeur le pose à côté des autres ; en essai, il
  /// vit sous le dossier du spike.
  public static func binaireParDefaut(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let chemin = environment["CORRESPONDANCE_TAILCAT"], !chemin.isEmpty {
      return URL(fileURLWithPath: (chemin as NSString).expandingTildeInPath)
    }
    let candidats = [
      CorrespondanceHome.sharedDirectory().appendingPathComponent("tailcat"),
      URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".correspondance-unclic/tailcat"),
      URL(fileURLWithPath: "/opt/homebrew/bin/tailcat"),
      URL(fileURLWithPath: "/usr/local/bin/tailcat"),
    ]
    return candidats.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  public private(set) var port: Int?
  public private(set) var derniereLigne: String?

  private var processus: Process?
  private let binaire: URL?

  public init(binaire: URL? = TailcatProxy.binaireParDefaut()) {
    self.binaire = binaire
  }

  public var estActif: Bool { processus?.isRunning == true && port != nil }

  /// Démarre `tailcat socks` sur un port local libre et attend qu'il l'annonce.
  ///
  /// On **lit le port dans la sortie du processus** au lieu de le supposer :
  /// `--listen=127.0.0.1:0` fait choisir le port par le système, ce qui évite
  /// la collision avec un `tailcat` déjà lancé à la main — et le spike a une
  /// règle là-dessus (vérifier un port avant de lier).
  @discardableResult
  public func demarrer(jeton: String, delai: TimeInterval = 15) async throws -> Int {
    if let port, estActif { return port }
    guard let binaire else { throw TailcatErreur.binaireIntrouvable }

    let tache = Process()
    tache.executableURL = binaire
    tache.arguments = ["socks", "--listen=127.0.0.1:0", jeton]
    let tuyau = Pipe()
    tache.standardOutput = tuyau
    tache.standardError = tuyau
    try tache.run()
    processus = tache

    let handle = tuyau.fileHandleForReading
    let echeance = Date().addingTimeInterval(delai)
    var tampon = ""
    while Date() < echeance {
      let morceau = handle.availableData
      if morceau.isEmpty {
        if !tache.isRunning { break }
        try? await Task.sleep(for: .milliseconds(100))
        continue
      }
      tampon += String(decoding: morceau, as: UTF8.self)
      derniereLigne = tampon.split(separator: "\n").last.map(String.init)
      // « SOCKS running at socks5h://127.0.0.1:53211 »
      if let plage = tampon.range(of: "socks5h://127.0.0.1:"),
         case let reste = tampon[plage.upperBound...],
         let numero = Int(reste.prefix(while: \.isNumber))
      {
        port = numero
        return numero
      }
    }
    arreter()
    throw TailcatErreur.pasDeMandataire(tampon.isEmpty ? "aucune sortie" : tampon)
  }

  public func arreter() {
    processus?.terminate()
    processus = nil
    port = nil
  }

  deinit { processus?.terminate() }
}

public enum TailcatErreur: LocalizedError {
  case binaireIntrouvable
  case pasDeMandataire(String)

  public var errorDescription: String? {
    switch self {
    case .binaireIntrouvable:
      "tailcat n'est pas installé sur cette machine — le Relais se joindra par son adresse ordinaire."
    case let .pasDeMandataire(sortie):
      "tailcat n'a pas ouvert de mandataire : \(sortie)"
    }
  }
}

/// La configuration d'`URLSession` qui fait passer tout le trafic Matrix par
/// le mandataire.
///
/// **Ce qu'il fallait vérifier, et non supposer** : le SOCKS5 de CFNetwork
/// envoie-t-il le *nom* au mandataire, ou le résout-il d'abord ? La question
/// décide de tout, parce que le mandataire de tailcat n'accepte **que** des
/// noms : `server.tailcat` (ou un addrblob), jamais une adresse IP — une IP
/// littérale y est comprise comme « sors par ce serveur vers cette adresse »,
/// c'est-à-dire un nœud de sortie, que notre Relais ne sert pas.
/// Mesuré : `URLSession` passe bien le nom (l'équivalent de `curl
/// --socks5-hostname`), donc `http://server.tailcat:8010` fonctionne.
///
/// Un piège de plus, muet et immédiat : `kCFNetworkProxiesSOCKSEnable` **vaut**
/// la chaîne `"SOCKSEnable"`. Écrire les deux dans le même littéral fait
/// « Dictionary literal contains duplicate keys » et tue le processus au
/// démarrage, sans un mot utile.
public enum MandataireSOCKS {
  public static func dictionnaire(port: Int) -> [String: Any] {
    [
      kCFNetworkProxiesSOCKSEnable as String: 1,
      kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
      kCFNetworkProxiesSOCKSPort as String: port,
    ]
  }

  public static func configuration(
    port: Int, base: URLSessionConfiguration = .ephemeral
  ) -> URLSessionConfiguration {
    let config = base
    config.connectionProxyDictionary = dictionnaire(port: port)
    return config
  }
}

#endif
