import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// L'adresse qu'un agent publie : celle du tailnet d'abord, parce que c'est
/// par elle que le Relais et les commandes SSH le joignent.
final class HostAddressTests: XCTestCase {
  func testLaPlageTailscaleEstReconnue() {
    XCTAssertTrue(AgentWire.estTailscale("100.64.0.1"))
    XCTAssertTrue(AgentWire.estTailscale("100.127.255.254"))
    XCTAssertFalse(AgentWire.estTailscale("100.128.0.1"))
    XCTAssertFalse(AgentWire.estTailscale("192.168.1.10"))
    XCTAssertFalse(AgentWire.estTailscale("pas une adresse"))
  }

  func testLeStatusPorteLAdresseQuandIlYEnAUne() {
    let avec = AgentEvents.status(body: "…", agent: "cc", host: "umbrel", pid: 1, address: "100.64.0.12")
    XCTAssertEqual(avec[AgentWire.StatusKey.address]?.stringValue, "100.64.0.12")
    let sans = AgentEvents.status(body: "…", agent: "cc", host: "umbrel", pid: 1, address: nil)
    XCTAssertNil(sans[AgentWire.StatusKey.address])
  }
}
