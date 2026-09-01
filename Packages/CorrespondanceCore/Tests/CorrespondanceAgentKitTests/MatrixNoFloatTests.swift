import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// **Matrix n'accepte aucun flottant dans un event.** Le JSON canonique ne
/// connaît que des entiers ; Synapse répond `400 Bad JSON value: float` et
/// l'event est perdu — sans bruit du côté de l'app, juste une ligne dans un
/// journal que personne ne lit.
///
/// Ça n'est pas une hypothèse : le journal des tours, l'un des trois garde-fous
/// qui remplacent la carte 👍 depuis la pleine permission, n'a **jamais** réussi
/// à s'écrire à cause d'une durée en secondes décimales. Ces tests existent pour
/// que ça n'arrive plus à aucun de nos events.
final class MatrixNoFloatTests: XCTestCase {

  // MARK: - La détection

  func testUnFlottantSeVoitEtSeNomme() {
    let contenu = MatrixJSON.object([
      "body": .string("salut"),
      "seconds": .number(5.4),
    ])
    XCTAssertEqual(contenu.nonIntegerNumberPaths(), ["seconds"], "le champ fautif doit être nommé")
  }

  func testUnEntierPasseMemeEcritEnDouble() {
    let contenu = MatrixJSON.object(["hourlyCap": .number(30), "version": .integer(1)])
    XCTAssertTrue(contenu.nonIntegerNumberPaths().isEmpty)
  }

  func testOnRegardeAussiDansLesObjetsEtLesTableaux() {
    let contenu = MatrixJSON.object([
      "outer": .object(["inner": .number(0.5)]),
      "list": .array([.number(1), .number(2.5)]),
    ])
    XCTAssertEqual(contenu.nonIntegerNumberPaths().sorted(), ["list[1]", "outer.inner"])
  }

  func testLInfiniEtLeNaNSontRefusesAussi() {
    XCTAssertFalse(MatrixJSON.object(["x": .number(.infinity)]).nonIntegerNumberPaths().isEmpty)
    XCTAssertFalse(MatrixJSON.object(["x": .number(.nan)]).nonIntegerNumberPaths().isEmpty)
  }

  // MARK: - Tous nos events, un par un

  func testLeJournalDUnTourNeContientAucunFlottant() {
    // La durée qui a tout cassé : 5,4 s.
    let contenu = AgentEvents.journal(
      agent: "cc", roomID: "!r:s", sender: "@g:s", prompt: "salut",
      tools: ["Bash"], seconds: 5.4321, tokens: 1234
    )
    XCTAssertEqual(contenu.nonIntegerNumberPaths(), [], "c'est exactement ce qui échouait")
    XCTAssertEqual(contenu.value(at: AgentWire.JournalKey.durationMs)?.intValue, 5432)
  }

  func testUnTourInstantaneEtUnTourTresLongPassentAussi() {
    for duree in [0.0, 0.0004, 1.0 / 3.0, 999.999, 3600.5] {
      let contenu = AgentEvents.journal(
        agent: "cc", roomID: "!r:s", sender: "@g:s", prompt: "x",
        tools: [], seconds: duree, tokens: nil
      )
      XCTAssertEqual(contenu.nonIntegerNumberPaths(), [], "durée \(duree)")
    }
  }

  func testLeStatusNeContientAucunFlottant() {
    let contenu = AgentEvents.status(body: "cc tourne sur umbrel depuis 14 h 02", agent: "cc")
    XCTAssertEqual(contenu.nonIntegerNumberPaths(), [])
  }

  func testLaPropositionEtLaPermissionNeContiennentAucunFlottant() {
    XCTAssertEqual(
      AgentEvents.proposal(text: "bonjour", agent: "cc", inReplyTo: "$e").nonIntegerNumberPaths(), []
    )
    XCTAssertEqual(
      AgentEvents.permission(body: "cc veut Bash", tool: "Bash", agent: "cc", inReplyTo: "$e")
        .nonIntegerNumberPaths(), []
    )
  }

  func testUneReponseEnThreadNeContientAucunFlottant() {
    XCTAssertEqual(
      AgentEvents.threadedText("voilà", root: "$r", lastEventID: "$l").nonIntegerNumberPaths(), []
    )
  }

  func testLaConfigDeLAgentNeContientAucunFlottant() {
    var config = AgentRemoteConfig(agent: "cc")
    config.owners = ["@g:s"]
    config.hourlyCap = 30
    config.trigger = "@cc"
    config.defaultMode = .draft
    config.backend = .acp
    config.rooms = ["!r:s": .init(cwd: "/tmp", mode: .direct)]
    XCTAssertEqual(config.content().nonIntegerNumberPaths(), [])
  }

  // MARK: - Le garde du client

  func testLeClientRefuseUnEventFautifAvantDeLEnvoyer() async {
    let client = MatrixClient(credentials: nil)
    do {
      _ = try await client.sendEvent(
        roomID: "!r:s", type: "fr.correspondance.test",
        content: .object(["seconds": .number(5.4)])
      )
      XCTFail("un flottant doit être refusé chez nous, pas par un 400 obscur")
    } catch let erreur as MatrixError {
      let texte = erreur.localizedDescription
      XCTAssertTrue(texte.contains("seconds"), texte)
      XCTAssertTrue(texte.contains("flottant"), texte)
    } catch {
      XCTFail("erreur inattendue : \(error)")
    }
  }

  func testLeGardeVautAussiPourLesEventsDEtat() async {
    let client = MatrixClient(credentials: nil)
    do {
      _ = try await client.sendStateEvent(
        roomID: "!r:s", type: AgentEvents.configType,
        content: .object(["hourlyCap": .number(30.5)])
      )
      XCTFail("une config avec un flottant doit être refusée")
    } catch let erreur as MatrixError {
      XCTAssertTrue(erreur.localizedDescription.contains("hourlyCap"))
    } catch {
      XCTFail("erreur inattendue : \(error)")
    }
  }
}
