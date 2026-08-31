import XCTest
import CorrespondanceMatrixClient
@testable import CorrespondanceAgentKit

/// L'agent choisit entre parler tout haut et proposer. Quatre voix peuvent le
/// dire ; l'ordre entre elles est ce que ces tests verrouillent.
final class AgentModeTests: XCTestCase {
  private func resolve(
    room: AgentConfig.RoomMode? = nil,
    private tete: Bool = false,
    accountData: AgentConfig.RoomMode? = nil,
    configured: AgentConfig.RoomMode = .draft
  ) -> AgentConfig.RoomMode {
    AgentMode.resolve(
      roomMode: room,
      isPrivateWithOwners: tete,
      accountDataDefault: accountData,
      configuredDefault: configured
    )
  }

  func testLeModeDeLaRoomPrimeSurToutLeReste() {
    XCTAssertEqual(resolve(room: .draft, private: true, accountData: .direct), .draft)
    XCTAssertEqual(resolve(room: .direct, private: false, accountData: .draft), .direct)
  }

  func testEnTeteATeteLAgentParleToutHaut() {
    XCTAssertEqual(resolve(private: true, accountData: .draft, configured: .draft), .direct)
  }

  func testDevantDesHumainsLeReglageDeLAppDecide() {
    XCTAssertEqual(resolve(private: false, accountData: .direct, configured: .draft), .direct)
    XCTAssertEqual(resolve(private: false, accountData: .draft, configured: .direct), .draft)
  }

  func testSansReglageEcritCEstLaConfigQuiDecide() {
    XCTAssertEqual(resolve(private: false, accountData: nil, configured: .draft), .draft)
    XCTAssertEqual(resolve(private: false, accountData: nil, configured: .direct), .direct)
  }

  // MARK: - Lecture de l'account data

  private func sync(_ accountData: String) throws -> MatrixSyncResponse {
    let json = """
    {"next_batch":"s1","account_data":{"events":[\(accountData)]}}
    """
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  func testLeSyncLivreLeModeParDefautEcritParLApp() throws {
    let response = try sync(
      """
      {"type":"fr.correspondance.agent.settings","content":{"default_mode":"direct"}}
      """
    )
    XCTAssertEqual(AgentMode.defaultMode(in: response), .direct)
  }

  func testUnSyncQuiNeParlePasDesReglagesNeDitRien() throws {
    let response = try sync(
      """
      {"type":"m.push_rules","content":{}}
      """
    )
    XCTAssertNil(AgentMode.defaultMode(in: response))
  }

  func testUnModeInconnuNEstPasUnMode() throws {
    let response = try sync(
      """
      {"type":"fr.correspondance.agent.settings","content":{"default_mode":"chuchoter"}}
      """
    )
    XCTAssertNil(AgentMode.defaultMode(in: response))
  }
}
