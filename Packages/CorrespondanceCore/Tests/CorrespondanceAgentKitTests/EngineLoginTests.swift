import CorrespondanceMatrixClient
import Foundation
import XCTest

@testable import CorrespondanceAgentKit

/// Installé n'est pas connecté : la preuve, c'est la trace que le `login` de
/// chaque CLI laisse sur le disque. Éprouvé sans toucher `~`.
final class EngineLoginTests: XCTestCase {
  func testCodexEstConnecteQuandSonAuthJSONExiste() {
    XCTAssertEqual(EngineLogin.isLoggedIn(engine: "codex", home: "/h", read: { $0 == "/h/.codex/auth.json" ? Data("{}".utf8) : nil }), true)
    XCTAssertEqual(EngineLogin.isLoggedIn(engine: "codex-acp", home: "/h", read: { _ in nil }), false)
  }

  /// `~/.claude.json` existe dès le premier lancement ; c'est `oauthAccount`
  /// qui prouve la session.
  func testClaudeEstConnecteParOauthAccountPasParLeFichier() {
    let sans = Data(#"{"numStartups": 3}"#.utf8)
    let avec = Data(#"{"numStartups": 3, "oauthAccount": {"emailAddress": "moi@exemple.fr"}}"#.utf8)
    XCTAssertEqual(EngineLogin.isLoggedIn(engine: "claude", home: "/h", read: { _ in sans }), false)
    XCTAssertEqual(EngineLogin.isLoggedIn(engine: "claude-code-acp", home: "/h", read: { _ in avec }), true)
  }

  func testSansPreuveConnueOnNeDitRien() {
    XCTAssertNil(EngineLogin.isLoggedIn(engine: "hermes", home: "/h", read: { _ in nil }))
    XCTAssertNil(EngineLogin.gesture(for: "hermes"))
  }

  func testLeStatusSepareLesPretsDeCeuxAConnecter() {
    let scan = EngineScan(
      engines: [
        .init(name: "claude", path: "/opt/homebrew/bin/claude", version: "2.1", loggedIn: true),
        .init(name: "grok", path: "/opt/homebrew/bin/grok", version: "1.0.13", loggedIn: false),
        .init(name: "hermes", path: nil, version: nil, loggedIn: nil),
      ],
      configuredEngine: "grok"
    )
    XCTAssertEqual(scan.statusLine(backend: .acp), "moteur acp · prêts : claude · à connecter : grok")
    XCTAssertTrue(scan.isPresent(.acp))
    XCTAssertTrue(scan.isLoggedOut(.acp))
    XCTAssertTrue(scan.reportFR(backend: .acp).contains("! grok"))
  }

  func testLeMessageDuMoteurNonConnecteDonneLeGeste() {
    let message = EngineScan.nonConnecteFR(engine: "codex-acp", host: "umbrel")
    XCTAssertTrue(message.hasPrefix("codex-acp est installé sur umbrel mais pas connecté"), message)
    XCTAssertTrue(message.contains("codex login"), message)
    XCTAssertTrue(message.contains("Réglages › Agents"), message)
  }
}
