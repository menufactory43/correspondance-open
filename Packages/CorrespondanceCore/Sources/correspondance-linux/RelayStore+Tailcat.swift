import CorrespondanceCore
import Foundation

/// Le chemin Tailcat, sous Linux — la suite du Mac (`InboxStore.connecterParLeCode`),
/// à la lettre : le mandataire est posé **avant** le `/login`, et si Tailcat
/// refuse, on tombe sur l'adresse du code plutôt que d'échouer.
@MainActor
extension RelayStore {
  /// Ouvre le chemin Tailcat vers le Relais et branche tout le trafic Matrix
  /// dessus. Rend le port local du mandataire.
  @discardableResult
  func ouvrirTailcat(jeton: String) async throws -> Int {
    let mandataire = tailcat ?? TailcatProxy()
    tailcat = mandataire
    // Le mandataire renaît s'il tombe, et son port change à chaque naissance.
    mandataire.auRedemarrage = { [weak self] port in
      guard let self else { return }
      await self.matrix.utiliserMandataireSOCKS(port: port)
      Self.log.notice("tailcat relancé, mandataire re-posé sur 127.0.0.1:\(port)")
    }
    let port = try await mandataire.demarrer(jeton: jeton)
    await matrix.utiliserMandataireSOCKS(port: port)
    return port
  }

  /// Se connecter à partir d'un code d'appairage : le chemin d'abord, la
  /// session ensuite. Rend la note à afficher (par où on est passé).
  @discardableResult
  func connecterParLeCode(_ code: RelayPairingCode) async -> String {
    var adresse = code.homeserver.absoluteString
    var note = "Relais joint \(code.chemin.titreFR)."
    if let jeton = code.tailcat, !jeton.isEmpty {
      do {
        let port = try await ouvrirTailcat(jeton: jeton)
        adresse = "http://server.tailcat:\(code.homeserver.port ?? 8010)"
        note = "Relais joint via Tailcat (mandataire local \(port))."
        tailcatJeton = jeton
        UserDefaults.standard.set(jeton, forKey: Self.tailcatJetonKey)
      } catch {
        note = "Tailcat n'a pas ouvert de chemin : \(error.localizedDescription) — on tente l'adresse du code."
      }
    }
    await connect(homeserver: adresse, user: code.userID, password: code.password)
    return note
  }

  /// Au lancement : si la session a été ouverte par Tailcat, le chemin est
  /// rouvert avant le premier `/sync` — sinon `server.tailcat` ne se résout pas.
  func rouvrirTailcatSiBesoin() async {
    guard tailcat == nil, let jeton = UserDefaults.standard.string(forKey: Self.tailcatJetonKey), !jeton.isEmpty else { return }
    tailcatJeton = jeton
    do { _ = try await ouvrirTailcat(jeton: jeton) } catch {
      syncError = "Tailcat n'a pas ouvert de chemin : \(error.localizedDescription)"
    }
  }

  /// Arrête le mandataire et retire la configuration du client.
  func fermerTailcat() {
    tailcat?.arreter()
    tailcat = nil
    tailcatJeton = nil
    UserDefaults.standard.removeObject(forKey: Self.tailcatJetonKey)
    Task { await matrix.utiliserMandataireSOCKS(port: nil) }
  }

  static let tailcatJetonKey = "correspondance.linux.tailcat"
}
