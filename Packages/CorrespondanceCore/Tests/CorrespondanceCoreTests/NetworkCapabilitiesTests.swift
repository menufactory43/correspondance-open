import XCTest
@testable import CorrespondanceCore

/// La table des capacités décide ce que l'app OSE proposer. Un faux « oui » n'y
/// coûte pas une erreur : il coûte un bouton qui ment.
final class NetworkCapabilitiesTests: XCTestCase {
  func testSeulMetaPorteLaModificationJusquAuReseau() {
    XCTAssertTrue(MessageNetwork.instagram.supportsEditing)
    XCTAssertFalse(MessageNetwork.whatsapp.supportsEditing)
    XCTAssertFalse(MessageNetwork.signal.supportsEditing)
    XCTAssertFalse(MessageNetwork.iMessage.supportsEditing)
  }

  /// La note à soi est un salon à nous : rien ne s'oppose à s'y corriger.
  func testLaNoteASoiSeCorrige() {
    XCTAssertTrue(MessageNetwork.selfNote.supportsEditing)
  }

  func testLeRenommageSuitLesPontsQuiLeRelaient() {
    XCTAssertTrue(MessageNetwork.whatsapp.supportsGroupRename)
    XCTAssertTrue(MessageNetwork.signal.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.instagram.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.iMessage.supportsGroupRename)
  }

  /// Retirer quelqu'un est le geste le plus irréversible du lot : on ne
  /// l'offre que là où le pont le fait vraiment sortir du groupe.
  func testLeRetraitNEstOffertQueLaOuIlPorte() {
    XCTAssertTrue(MessageNetwork.whatsapp.supportsMemberRemoval)
    XCTAssertTrue(MessageNetwork.signal.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.instagram.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.iMessage.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.selfNote.supportsMemberRemoval)
  }

  func testAjouterQuelquUnSuitLesPontsQuiOntUnGhostComposable() {
    for network in [MessageNetwork.whatsapp, .instagram, .signal] {
      XCTAssertTrue(network.supportsMemberInvite, "\(network.labelFR) devrait accepter l'ajout")
    }
    XCTAssertFalse(MessageNetwork.iMessage.supportsMemberInvite)
  }

  /// iMessage n'envoie pas de pièce jointe par notre chemin : pas de micro.
  func testLeVocalEstOffertPartoutSaufSurIMessage() {
    for network in [MessageNetwork.whatsapp, .instagram, .signal, .selfNote] {
      XCTAssertTrue(network.supportsVoiceMessages, "\(network.labelFR) devrait accepter le vocal")
    }
    XCTAssertFalse(MessageNetwork.iMessage.supportsVoiceMessages)
  }

  /// Aucun pont n'expose la création de portail depuis Matrix : la table le dit
  /// pour que personne ne dessine l'écran avant que ce soit vrai.
  func testAucunReseauNeCreeDeGroupeDepuisLApp() {
    for network in MessageNetwork.allCases {
      XCTAssertFalse(network.capabilities.createsGroup, "\(network.labelFR)")
    }
  }
}
