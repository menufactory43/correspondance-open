import Foundation
import CorrespondanceMatrixClient

/// Ce que les deux écrans du chiffrement demandent au Relais.
///
/// Il passe par le service et non par `MatrixClient` pour la même raison que
/// `etatDuChiffrement()` : un écran n'a aucune raison de connaître le client,
/// et un binaire construit sans la machine crypto doit répondre quelque chose
/// plutôt que planter.
extension MatrixBridgeService {

  /// La liste des appareils du compte : ce que le serveur en sait (nom,
  /// dernière activité) recollé à ce que la machine crypto en sait (vérifié ou
  /// non).
  public func appareilsAAfficher() async -> [MatrixAppareilVu] {
    (try? await client.appareilsAAfficher()) ?? []
  }

  /// La version de sauvegarde que le Relais héberge, s'il en héberge une.
  /// C'est **le** fait qui décide de l'écran : sans elle on propose de créer
  /// une phrase, avec elle on demande celle qui existe.
  public func versionDeSauvegardeDuRelais() async -> String? {
    (try? await client.versionDeSauvegarde())??.version
  }

  /// Crée la sauvegarde à partir d'une phrase, puis y pousse les clés qu'on a
  /// déjà. Sans le second temps, la sauvegarde existe et ne contient rien.
  @discardableResult
  public func creerLaSauvegarde(phrase: String, remplacerLExistante: Bool = false) async throws
    -> Int
  {
    try await client.creerSauvegarde(phrase: phrase, remplacerLExistante: remplacerLExistante)
    return try await client.sauvegarderLesCles()
  }

  /// L'appareil neuf : la phrase, et rien d'autre. Restaure les clés de salon,
  /// puis reprend les clés de signature du coffre — c'est ce second temps qui
  /// rend l'appareil *vérifié* sans comparer d'émojis.
  public func rejoindreLaSauvegarde(phrase: String) async throws -> MatrixImportDeCles {
    let import_ = try await client.rejoindreSauvegarde(phrase: phrase)
    // Le coffre peut être absent (compte d'avant la phase 5) : ce n'est pas un
    // échec de la restauration, et l'écran doit quand même dire « clés reprises ».
    try? await client.reprendreLesSignaturesDuCoffre(phrase: phrase)
    return import_
  }

  /// Dépose les clés de signature dans le coffre pour les appareils à venir.
  public func deposerLesSignatures(phrase: String) async throws {
    try await client.deposerLesSignaturesDansLeCoffre(phrase: phrase)
  }

  /// Pose les signatures croisées si elles manquent. Le mot de passe n'est
  /// exigé que par un compte qui porte déjà des clés (piège de la phase 5).
  public func amorcerLesSignatures(motDePasse: String?) async throws {
    _ = try await client.amorcerSignaturesCroisees(motDePasse: motDePasse)
  }

  public func deconnecterAppareil(_ deviceID: String, motDePasse: String?) async throws
    -> MatrixDeconnexionAppareil
  {
    try await client.deconnecterAppareil(deviceID, motDePasse: motDePasse)
  }

  /// L'identifiant de l'appareil courant — celui qu'on ne propose jamais de
  /// déconnecter depuis cet écran.
  public func appareilCourant() async -> String? {
    await client.currentCredentials?.deviceID
  }
}
