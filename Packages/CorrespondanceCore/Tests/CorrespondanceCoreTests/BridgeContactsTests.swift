import XCTest
@testable import CorrespondanceCore

/// Le carnet de Signal, lu au pont : c'est lui qui permet d'écrire à quelqu'un
/// avec qui on n'a aucun fil, comme depuis l'app Signal.
final class BridgeContactsTests: XCTestCase {
  func testDecodesTheProvisioningContactList() throws {
    let json = """
    {"contacts":[
      {"id":"186ab242-d528-4070-b979-97b7543f9138","name":"Jeanne","mxid":"@signal_186ab242:correspondance.local"},
      {"id":"6eade43a-a2c2-4950-9993-0b527f629fbd","name":"Paul","identifiers":["tel:+33612345678"],
       "dm_room_mxid":"!BAMC:correspondance.local"},
      {"id":"b32adcf4-fad8-4f78-b83d-4d21e370ec1e","name":"  "}
    ]}
    """
    let contacts = try BridgeContact.decodeList(Data(json.utf8))
    XCTAssertEqual(contacts.map(\.name), ["Jeanne", "Paul"], "un contact sans nom n'est qu'un UUID")
    XCTAssertNil(contacts[0].phone)
    XCTAssertEqual(contacts[1].phone, "+33612345678")
    XCTAssertEqual(contacts[1].dmRoomID, "!BAMC:correspondance.local")
  }

  func testEmptyResponseIsNoContacts() throws {
    XCTAssertEqual(try BridgeContact.decodeList(Data("{}".utf8)), [])
  }
}
