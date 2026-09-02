import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Un ordre dans la console : pour cet agent, et pas pour le voisin.
final class AgentCommandEventTests: XCTestCase {
  func testUnOrdreSeLitPourSonAgentSeulement() {
    let content = MatrixJSON.object([
      AgentWire.CommandKey.agent: .string("cc"),
      AgentWire.CommandKey.command: .string(AgentWire.Command.rescan),
    ])
    XCTAssertEqual(AgentEvents.command(in: content, agent: "cc"), "rescan")
    XCTAssertNil(AgentEvents.command(in: content, agent: "hermes"))
    XCTAssertNil(AgentEvents.command(in: .object([:]), agent: "cc"))
  }
}
