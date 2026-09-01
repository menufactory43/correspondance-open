import XCTest

@testable import CorrespondanceAgentKit

/// Ce qu'on garde chaud, et ce qu'on laisse s'éteindre. Mesuré dans
/// `docs/SPIKE-acp.md` : un tour froid paie ~2,9 s de démarrage.
final class ACPEnginePoolTests: XCTestCase {
  let now = Date()

  func testUnMoteurSilencieuxTropLongtempsSEteint() {
    let policy = ACPEnginePool.Policy(idleSeconds: 600)
    XCTAssertFalse(policy.isExpired(lastUsed: now.addingTimeInterval(-599), now: now))
    XCTAssertTrue(policy.isExpired(lastUsed: now.addingTimeInterval(-601), now: now))
  }

  func testEnDessousDuPlafondPersonneNeSEteint() {
    let policy = ACPEnginePool.Policy(maxEngines: 4)
    let engines = (0..<4).map { (key: "!room\($0)", lastUsed: now) }
    XCTAssertNil(policy.victim(among: engines))
  }

  func testAuDelaDuPlafondCEstLePlusAncienQuiPart() {
    let policy = ACPEnginePool.Policy(maxEngines: 2)
    let engines = [
      (key: "!recente", lastUsed: now),
      (key: "!ancienne", lastUsed: now.addingTimeInterval(-3600)),
      (key: "!moyenne", lastUsed: now.addingTimeInterval(-60)),
    ]
    XCTAssertEqual(policy.victim(among: engines), "!ancienne")
  }

  /// Le repli existe pour un adaptateur absent ou muet — pas pour un moteur qui
  /// a répondu quelque chose qui déplaît, ni pour un tour trop long (le rejouer
  /// ailleurs le paierait deux fois).
  func testCeQuiJustifieUnRepli() {
    XCTAssertTrue(FallbackBackend.isStartupFailure(.binaryNotFound))
    XCTAssertTrue(FallbackBackend.isStartupFailure(.unreadableOutput("pas du JSON-RPC")))
    XCTAssertTrue(FallbackBackend.isStartupFailure(.exit(code: 1, stderr: "boom")))
    XCTAssertFalse(FallbackBackend.isStartupFailure(.timedOut(seconds: 600)))
  }

  func testLeReplirépondQuandLePremierMoteurManque() async throws {
    let absent = MoteurQuiEchoue(error: .binaryNotFound)
    let cli = MoteurQuiRepond(text: "réponse de la CLI")
    let backend = FallbackBackend(primary: absent, secondary: cli)

    let premier = try await backend.run(prompt: "salut", cwd: nil, sessionID: nil)
    XCTAssertEqual(premier.text, "réponse de la CLI")
    let secondBool = await backend.isFallenBack
    XCTAssertTrue(secondBool, "le repli est collant : on ne réessaie pas à chaque message")
    var appelsAbsent = await absent.appels
    XCTAssertEqual(appelsAbsent, 1, "le moteur absent n'est plus sollicité")

    _ = try await backend.run(prompt: "encore", cwd: nil, sessionID: nil)
    appelsAbsent = await absent.appels
    let appelsCLI = await cli.appels
    XCTAssertEqual(appelsAbsent, 1)
    XCTAssertEqual(appelsCLI, 2)
  }

  func testUnTourTropLongNeBasculePasSurLAutreMoteur() async {
    let lent = MoteurQuiEchoue(error: .timedOut(seconds: 600))
    let cli = MoteurQuiRepond(text: "jamais")
    let backend = FallbackBackend(primary: lent, secondary: cli)
    do {
      _ = try await backend.run(prompt: "salut", cwd: nil, sessionID: nil)
      XCTFail("un tour trop long doit remonter, pas se rejouer ailleurs")
    } catch {
      let appels = await cli.appels
      XCTAssertEqual(appels, 0)
    }
  }
}

private actor MoteurQuiEchoue: AgentBackend {
  let error: AgentBackendError
  private(set) var appels = 0

  init(error: AgentBackendError) { self.error = error }

  func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    appels += 1
    throw error
  }
}

private actor MoteurQuiRepond: AgentBackend {
  let text: String
  private(set) var appels = 0

  init(text: String) { self.text = text }

  func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    appels += 1
    return AgentTurn(text: text, sessionID: "s1")
  }
}
