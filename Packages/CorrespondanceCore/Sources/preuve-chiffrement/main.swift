import Foundation
import CorrespondanceMatrixClient
import CorrespondanceMatrixCrypto

// Correspondance — la preuve du chiffrement, phase 2 du spike « un clic ».
//
// Un client Matrix minuscule qui utilise **le vrai** `MatrixClient` de l'app et
// **le vrai** `RustCryptoEngine` : ce qu'il prouve, l'app le fait.
//
//   preuve-chiffrement envoyer <profil> <salon|--nouveau> <texte>
//   preuve-chiffrement lire    <profil> <salon>
//   preuve-chiffrement salons  <profil>
//
// Un « profil » est un appareil : sa session et son magasin de clés vivent sous
// $PREUVE_HOME/<profil>/. Deux profils = deux appareils du même compte, ce qui
// est exactement ce que la preuve B demande.

struct Session: Codable {
  var homeserver: String
  var userID: String
  var accessToken: String
  var deviceID: String
}

if ProcessInfo.processInfo.environment["PREUVE_JOURNAL"] == "1" {
  RustCryptoEngine.journaliserSurStderr()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let commande = args.first else {
  FileHandle.standardError.write(Data("usage: preuve-chiffrement <envoyer|lire|salons> …\n".utf8))
  exit(2)
}

let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PREUVE_HOME"]
  ?? NSHomeDirectory() + "/.correspondance-unclic/preuve")
let homeserver = URL(string: ProcessInfo.processInfo.environment["RELAIS_URL"] ?? "http://127.0.0.1:8010")!
let utilisateur = ProcessInfo.processInfo.environment["MATRIX_USER"] ?? "essai"
let motDePasse = ProcessInfo.processInfo.environment["MATRIX_PASSWORD"] ?? ""

func dire(_ texte: String) { print(texte); fflush(stdout) }

func dossier(_ profil: String) -> URL {
  base.appendingPathComponent(profil, isDirectory: true)
}

/// Ouvre (ou rouvre) la session du profil, puis branche sa machine crypto.
/// Rouvrir avec le jeton enregistré, c'est exactement « l'app relancée » :
/// même `device_id`, même magasin de clés sur le disque.
func client(_ profil: String) async throws -> (MatrixClient, Session, RustCryptoEngine) {
  let racine = dossier(profil)
  try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
  let fichier = racine.appendingPathComponent("session.json")

  var session: Session
  if let data = try? Data(contentsOf: fichier), let s = try? JSONDecoder().decode(Session.self, from: data) {
    session = s
    dire("→ session reprise : \(s.userID) / appareil \(s.deviceID)")
  } else {
    guard !motDePasse.isEmpty else { throw NSError(domain: "preuve", code: 1, userInfo: [NSLocalizedDescriptionKey: "MATRIX_PASSWORD manquant"]) }
    MatrixClient.deviceDisplayName = "Preuve chiffrement · \(profil)"
    let neuf = MatrixClient()
    let creds = try await neuf.login(homeserver: homeserver, user: utilisateur, password: motDePasse)
    session = Session(
      homeserver: homeserver.absoluteString, userID: creds.userID,
      accessToken: creds.accessToken, deviceID: creds.deviceID ?? "?"
    )
    try JSONEncoder().encode(session).write(to: fichier)
    dire("→ session neuve : \(session.userID) / appareil \(session.deviceID)")
  }

  let creds = MatrixCredentials(
    homeserver: URL(string: session.homeserver)!, userID: session.userID,
    accessToken: session.accessToken, deviceID: session.deviceID
  )
  let c = MatrixClient(credentials: creds)
  let moteur = try RustCryptoEngine(
    userID: session.userID, deviceID: session.deviceID,
    dossier: racine.appendingPathComponent("crypto", isDirectory: true)
  )
  await c.setCrypto(moteur)
  let cles = await moteur.clesDIdentite()
  dire("→ machine crypto : magasin \(racine.appendingPathComponent("crypto").path)")
  dire("  curve25519 \(cles["curve25519"] ?? "?") · ed25519 \(cles["ed25519"] ?? "?")")
  return (c, session, moteur)
}

/// Quelques tours de `/sync` : le premier publie nos clés, les suivants
/// ramassent les `to_device` qui portent les clés de salon. Le dernier tour
/// est un `/sync` initial (`since` nul) : c'est celui qui rapporte la timeline
/// une fois les clés arrivées — exactement ce que l'app fait au démarrage.
@discardableResult
func synchroniser(_ c: MatrixClient, tours: Int = 3) async throws -> MatrixSyncResponse {
  var depuis: String? = nil
  var derniere: MatrixSyncResponse!
  for tour in 1...tours {
    let initial = (depuis == nil) || (tour == tours)
    derniere = try await c.sync(since: initial ? nil : depuis, timeoutMilliseconds: initial ? 0 : 3000)
    depuis = derniere.nextBatch
    let j = await c.dernierJournalCrypto
    dire("  /sync #\(tour)\(initial ? " (initial)" : "") — \(j.resume)")
    for td in await c.journalCryptoToDeviceBruts { dire("    to_device brut : \(td)") }
    for td in await c.journalCryptoToDevice {
      let j = try? JSONDecoder().decode(MatrixJSON.self, from: Data(td.utf8))
      dire("    to_device lu : type=\(j?.string(at: "type") ?? "?") de \(j?.string(at: "sender") ?? "?")")
    }
    if let e = await c.journalCryptoErreur { dire("    (note : \(e))") }
  }
  return derniere
}

func nomDuSalon(_ c: MatrixClient, _ roomID: String) async -> String {
  ((try? await c.roomState(roomID: roomID, type: "m.room.name"))?.string(at: "name")) ?? "(sans nom)"
}

do {
  switch commande {
  case "envoyer":
    guard args.count >= 4 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "envoyer <profil> <salon|--nouveau> <texte>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let salon: String
    if args[2] == "--nouveau" {
      salon = try await c.createSelfRoom(name: "Note à soi (chiffrée)", chiffre: true)
      dire("→ salon créé, chiffré à la création : \(salon)")
      let etat = try await c.roomState(roomID: salon, type: "m.room.encryption")
      dire("  m.room.encryption = \(etat.string(at: "algorithm") ?? "(absent)")")
    } else {
      salon = args[2]
      dire("→ salon \(salon) — chiffré ? \(await c.salonEstChiffre(salon))")
    }
    let membres = try await c.membresRejoints(roomID: salon)
    dire("→ membres du salon : \(membres.joined(separator: ", "))")
    let id = try await c.sendText(roomID: salon, body: args[3])
    dire("→ envoyé : \(id ?? "?")")
    let brut = try await c.roomEvent(roomID: salon, eventID: id ?? "")
    dire("→ ce que le Relais stocke : type=\(brut.string(at: "type") ?? "?") algorithm=\(brut.string(at: "content.algorithm") ?? "—")")
    dire("  ciphertext (100 premiers) : \(String((brut.string(at: "content.ciphertext") ?? "").prefix(100)))…")
    dire("SALON=\(salon)")

  case "lire":
    guard args.count >= 3 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "lire <profil> <salon>"]) }
    let (c, _, _) = try await client(args[1])
    let salon = args[2]
    let reponse = try await synchroniser(c, tours: 4)
    let j = await c.dernierJournalCrypto
    dire("→ journal du dernier /sync : \(j.resume)")
    dire("→ salons que le client sait chiffrés : \(await c.salonsChiffres.sorted().joined(separator: ", "))")
    guard let pieces = reponse.rooms?.join?[salon] else {
      dire("✗ le salon \(salon) n'est pas dans ce /sync")
      exit(1)
    }
    var lus = 0
    for e in pieces.timeline?.events ?? [] {
      switch e.type {
      case "m.room.message":
        lus += 1
        dire("  ✓ \(e.sender ?? "?") : « \(e.content?.string(at: "body") ?? "") »   (event \(e.eventID ?? "?"))")
      case "m.room.encrypted":
        dire("  ✗ resté chiffré : \(e.eventID ?? "?")")
      default:
        // Les events **qui ne sont pas des messages** comptent aussi : le
        // journal des tours de `cc` (`fr.correspondance.agent.journal`) part
        // chiffré comme le reste, et il faut prouver qu'il se relit.
        if e.type.hasPrefix("fr.correspondance.") {
          lus += 1
          let brut = (try? JSONEncoder().encode(e.content ?? .object([:]))).flatMap {
            String(data: $0, encoding: .utf8)
          } ?? "{}"
          dire("  ✓ \(e.sender ?? "?") : [\(e.type)] \(brut)")
        }
      }
    }
    dire(lus > 0 ? "→ \(lus) message(s) lu(s) en clair." : "→ aucun message lisible.")

  case "chiffrer-salon":
    // Poser `m.room.encryption` sur un salon qui existe déjà — le salon de
    // gestion d'un pont, par exemple. Ce qui est écrit avant reste en clair :
    // un salon ne se chiffre jamais rétroactivement.
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    _ = try await c.sendStateEvent(
      roomID: args[2], type: "m.room.encryption",
      content: .object(["algorithm": .string("m.megolm.v1.aes-sha2")])
    )
    await c.marquerSalonChiffre(args[2])
    let etat = try await c.roomState(roomID: args[2], type: "m.room.encryption")
    dire("→ \(args[2]) : m.room.encryption = \(etat.string(at: "algorithm") ?? "(absent)")")
    dire("→ membres : \((try await c.membresRejoints(roomID: args[2])).joined(separator: ", "))")

  // Inviter quelqu'un dans un salon — `cc`, en l'occurrence. Un agent qui
  // n'est pas membre ne reçoit pas la clé de salon : le partage vise les
  // **membres rejoints**, pas les invités.
  case "inviter":
    guard args.count >= 4 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "inviter <profil> <salon> <userID>"]) }
    let (c, _, _) = try await client(args[1])
    try await c.invite(roomID: args[2], userID: args[3])
    dire("→ \(args[3]) invité dans \(args[2])")

  // La room console de `cc`, **chiffrée**, avec l'event d'état que l'app y
  // écrit. C'est ce que « Activer cc » fait dans l'app ; le refaire ici rend la
  // preuve rejouable sans piloter une fenêtre.
  case "console":
    guard args.count >= 4 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "console <profil> <agent> <userID de l'agent>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let console = try await c.createSelfRoom(name: "Console \(args[2]) (chiffrée)", chiffre: true)
    dire("→ console créée, chiffrée à la création : \(console)")
    _ = try await c.sendStateEvent(
      roomID: console, type: AgentWire.configType,
      content: .object([
        AgentWire.ConfigKey.version: .number(Double(AgentWire.configVersion)),
        AgentWire.ConfigKey.agent: .string(args[2]),
      ])
    )
    try await c.invite(roomID: console, userID: args[3])
    dire("→ \(AgentWire.configType) posé, \(args[3]) invité")
    dire("CONSOLE=\(console)")

  // La sauvegarde des clés : on la crée depuis une phrase et on téléverse tout
  // ce que la machine détient. C'est ce qui fera lire l'historique à un
  // appareil qui n'existait pas encore.
  case "sauvegarder":
    guard args.count >= 3 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "sauvegarder <profil> <phrase>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let version = try await c.creerSauvegarde(phrase: args[2], remplacerLExistante: true)
    dire("→ sauvegarde créée, version \(version)")
    let fournees = try await c.sauvegarderLesCles()
    dire("→ \(fournees) fournée(s) de clés téléversée(s) en plus")
    if let (v, auth) = try await c.versionDeSauvegarde() {
      dire("→ ce que le Relais annonce : version=\(v) public_key=\(auth.string(at: "public_key") ?? "?")")
      dire("  private_key_salt=\(auth.string(at: "private_key_salt") ?? "(absent)") iterations=\(auth.value(at: "private_key_iterations")?.intValue ?? -1)")
    }
    dire("VERSION=\(version)")

  // L'appareil neuf qui n'a que la phrase.
  case "restaurer":
    guard args.count >= 3 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "restaurer <profil> <phrase>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let bilan = try await c.rejoindreSauvegarde(phrase: args[2])
    dire("→ clés réimportées : \(bilan.importees) sur \(bilan.total)")

  case "etat":
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let etat = await c.etatDuChiffrement()
    dire("→ \(etat.resumeFR)  (appareil \(etat.appareilID ?? "?"))")

  // Les signatures croisées : la clé maîtresse, la self-signing, la
  // user-signing. À faire une fois, sur le premier appareil.
  case "amorcer-signatures":
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    let amorce = try await c.amorcerSignaturesCroisees(motDePasse: motDePasse)
    dire("→ clés de signature croisée posées sur le compte")
    for (nom, cle) in [("maîtresse", amorce.cleMaitresse), ("self-signing", amorce.cleSelfSigning), ("user-signing", amorce.cleUserSigning)] {
      let j = try? JSONDecoder().decode(MatrixJSON.self, from: Data(cle.utf8))
      dire("  \(nom) : \((j?["keys"]?.objectValue?.keys.sorted() ?? []).joined(separator: ", "))")
    }

  case "appareils":
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    for a in try await c.appareilsDuCompte() {
      dire("  \(a.deviceID)\(a.estMoi ? " (moi)" : "")  \(a.nom ?? "(sans nom)")  — \(a.etatFR)")
    }

  case "verifier":
    guard args.count >= 4 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "verifier <profil> <userID> <deviceID>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    _ = try await c.appareilsDuCompte()
    try await c.verifierAppareil(userID: args[2], deviceID: args[3])
    dire("→ \(args[3]) signé par la clé self-signing")

  // Porter les clés privées de signature croisée à un appareil neuf, chiffrées
  // par la phrase dans le stockage secret (4S). C'est ce qui rend un appareil
  // « vérifié par la phrase » sans comparer d'émojis.
  case "deposer-signatures":
    guard args.count >= 3 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "deposer-signatures <profil> <phrase>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    try await c.deposerLesSignaturesDansLeCoffre(phrase: args[2])
    dire("→ clés de signature croisée déposées, chiffrées par la phrase")

  case "reprendre-signatures":
    guard args.count >= 3 else { throw NSError(domain: "preuve", code: 2, userInfo: [NSLocalizedDescriptionKey: "reprendre-signatures <profil> <phrase>"]) }
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    try await c.reprendreLesSignaturesDuCoffre(phrase: args[2])
    let etat = await c.etatDuChiffrement()
    dire("→ \(etat.resumeFR)")

  case "salons":
    let (c, _, _) = try await client(args[1])
    try await synchroniser(c, tours: 2)
    for salon in try await c.joinedRooms() {
      dire("  \(salon)  \(await nomDuSalon(c, salon))  chiffré=\(await c.salonEstChiffre(salon))")
    }

  default:
    FileHandle.standardError.write(Data("commande inconnue : \(commande)\n".utf8))
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
  exit(1)
}
