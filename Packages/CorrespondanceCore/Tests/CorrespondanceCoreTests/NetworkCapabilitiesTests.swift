import XCTest
@testable import CorrespondanceCore

/// La table des capacités décide ce que l'app OSE proposer. Un faux « oui » n'y
/// coûte pas une erreur : il coûte un bouton qui ment.
final class NetworkCapabilitiesTests: XCTestCase {
  /// Les quatre réseaux bridgés portent la correction : leurs ponts l'annoncent
  /// tous en `edit: 2` dans le `com.beeper.room_features` du salon. iMessage
  /// reste dehors — il n'a pas de pont, il a l'automatisation Messages.
  func testLesPontsPortentTousLaModification() {
    for network in [MessageNetwork.instagram, .messenger, .whatsapp, .signal] {
      XCTAssertTrue(network.supportsEditing, "\(network.labelFR) devrait modifier")
    }
    XCTAssertFalse(MessageNetwork.iMessage.supportsEditing)
  }

  /// Chacun sa fenêtre, et elle vient du pont, pas de nous.
  func testChaqueReseauSaFenetre() {
    XCTAssertEqual(MessageNetwork.messenger.capabilities.editWindow, 15 * 60)
    XCTAssertEqual(MessageNetwork.instagram.capabilities.editWindow, 15 * 60)
    XCTAssertEqual(MessageNetwork.whatsapp.capabilities.editWindow, 15 * 60)
    XCTAssertEqual(MessageNetwork.signal.capabilities.editWindow, 24 * 3600)
  }

  /// Une capacité a une durée. Meta relaie le `m.replace` — quinze minutes.
  /// Au-delà, le pont le jette sans un mot : le geste doit disparaître avant.
  func testLaModificationMetaSeFermeApresQuinzeMinutes() {
    let envoi = Date(timeIntervalSince1970: 1_800_000_000)
    for network in [MessageNetwork.instagram, .messenger] {
      XCTAssertTrue(network.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(60)))
      XCTAssertTrue(network.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(14 * 60 + 59)))
      XCTAssertFalse(network.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(15 * 60)))
      // Le cas vu en vrai : une correction six heures après l'envoi, appliquée
      // chez nous et nulle part ailleurs.
      XCTAssertFalse(network.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(6 * 3600)))
    }
  }

  /// Un réseau qui ne modifie pas ne modifie à aucune heure : le délai ne
  /// rouvre jamais une capacité absente.
  func testLeDelaiNOuvrePasCeQueLePontNePortePas() {
    let envoi = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertFalse(MessageNetwork.iMessage.acceptsEdit(sentAt: envoi, now: envoi))
  }

  /// Signal laisse vingt-quatre heures : la veille au soir passe, l'avant-veille
  /// non. Une fenêtre large reste une fenêtre.
  func testSignalTientVingtQuatreHeures() {
    let envoi = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertTrue(MessageNetwork.signal.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(23 * 3600)))
    XCTAssertFalse(MessageNetwork.signal.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(25 * 3600)))
    // WhatsApp, lui, est aussi court que Meta.
    XCTAssertFalse(MessageNetwork.whatsapp.acceptsEdit(sentAt: envoi, now: envoi.addingTimeInterval(20 * 60)))
  }

  /// Sans fenêtre déclarée, pas de limite : notre salon à nous n'expire pas.
  func testLaNoteASoiNExpirePas() {
    let vieux = Date(timeIntervalSince1970: 1_000_000_000)
    XCTAssertNil(MessageNetwork.selfNote.capabilities.editWindow)
    XCTAssertTrue(MessageNetwork.selfNote.acceptsEdit(sentAt: vieux, now: Date()))
  }

  /// Les délais de Messages ne passent par aucun pont — ils ne sont pas dans la
  /// table, mais ils bornent les mêmes gestes.
  func testLesFenetresDeLAutomatisationMessages() {
    let envoi = Date(timeIntervalSince1970: 1_800_000_000)
    let edit = MessagesAutomationWindow.edit
    let annuler = MessagesAutomationWindow.undoSend
    XCTAssertEqual(edit, 15 * 60)
    XCTAssertEqual(annuler, 2 * 60)
    XCTAssertTrue(MessagesAutomationWindow.isOpen(edit, since: envoi, now: envoi.addingTimeInterval(14 * 60)))
    XCTAssertFalse(MessagesAutomationWindow.isOpen(edit, since: envoi, now: envoi.addingTimeInterval(16 * 60)))
    XCTAssertTrue(MessagesAutomationWindow.isOpen(annuler, since: envoi, now: envoi.addingTimeInterval(90)))
    XCTAssertFalse(MessagesAutomationWindow.isOpen(annuler, since: envoi, now: envoi.addingTimeInterval(150)))
  }

  /// « Supprimer pour tout le monde » a sa propre fenêtre, plus large que la
  /// correction, et Meta n'en a pas du tout : chaque geste son délai.
  func testLaSuppressionPourToutLeMondeASaPropreFenetre() {
    let envoi = Date(timeIntervalSince1970: 1_800_000_000)
    let apres30h = envoi.addingTimeInterval(30 * 3600)
    XCTAssertFalse(MessageNetwork.signal.acceptsDeleteForEveryone(sentAt: envoi, now: apres30h))
    XCTAssertTrue(MessageNetwork.whatsapp.acceptsDeleteForEveryone(sentAt: envoi, now: apres30h))
    XCTAssertFalse(
      MessageNetwork.whatsapp.acceptsDeleteForEveryone(sentAt: envoi, now: envoi.addingTimeInterval(49 * 3600))
    )
    // Meta ne referme jamais : un message d'il y a un an se retire encore.
    XCTAssertTrue(
      MessageNetwork.messenger.acceptsDeleteForEveryone(sentAt: envoi, now: envoi.addingTimeInterval(365 * 24 * 3600))
    )
    // Et une correction n'est plus possible bien avant la suppression.
    XCTAssertFalse(MessageNetwork.signal.acceptsEdit(sentAt: envoi, now: apres30h))
  }

  /// Un délai s'écrit pour être lu : c'est ce que l'app met dans son refus.
  func testLesDelaisSeDisentEnToutesLettres() {
    XCTAssertEqual(MessageNetwork.messenger.editWindowLabelFR, "15 minutes")
    XCTAssertEqual(MessageNetwork.signal.editWindowLabelFR, "24 heures")
    XCTAssertEqual(MessageNetwork.whatsapp.deleteWindowLabelFR, "48 heures")
    XCTAssertNil(MessageNetwork.messenger.deleteWindowLabelFR)
    XCTAssertNil(MessageNetwork.selfNote.editWindowLabelFR)
  }

  /// La note à soi est un salon à nous : rien ne s'oppose à s'y corriger.
  func testLaNoteASoiSeCorrige() {
    XCTAssertTrue(MessageNetwork.selfNote.supportsEditing)
  }

  func testLeRenommageSuitLesPontsQuiLeRelaient() {
    XCTAssertTrue(MessageNetwork.whatsapp.supportsGroupRename)
    XCTAssertTrue(MessageNetwork.signal.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.instagram.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.messenger.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.iMessage.supportsGroupRename)
  }

  /// Retirer quelqu'un est le geste le plus irréversible du lot : on ne
  /// l'offre que là où le pont le fait vraiment sortir du groupe.
  func testLeRetraitNEstOffertQueLaOuIlPorte() {
    XCTAssertTrue(MessageNetwork.whatsapp.supportsMemberRemoval)
    XCTAssertTrue(MessageNetwork.signal.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.instagram.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.messenger.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.iMessage.supportsMemberRemoval)
    XCTAssertFalse(MessageNetwork.selfNote.supportsMemberRemoval)
  }

  func testAjouterQuelquUnSuitLesPontsQuiOntUnGhostComposable() {
    for network in [MessageNetwork.whatsapp, .instagram, .messenger, .signal] {
      XCTAssertTrue(network.supportsMemberInvite, "\(network.labelFR) devrait accepter l'ajout")
    }
    XCTAssertFalse(MessageNetwork.iMessage.supportsMemberInvite)
  }

  /// iMessage n'envoie pas de pièce jointe par notre chemin : pas de micro.
  func testLeVocalEstOffertPartoutSaufSurIMessage() {
    for network in [MessageNetwork.whatsapp, .instagram, .messenger, .signal, .selfNote] {
      XCTAssertTrue(network.supportsVoiceMessages, "\(network.labelFR) devrait accepter le vocal")
    }
    XCTAssertFalse(MessageNetwork.iMessage.supportsVoiceMessages)
  }

  /// Créer un groupe passe par `create-group` (bridgev2) : WhatsApp et Signal
  /// l'implémentent, mautrix-meta ne l'annonce que pour des groupes NON
  /// chiffrés — non vérifié, donc non proposé.
  func testSeulsWhatsAppEtSignalCreentUnGroupe() {
    XCTAssertTrue(MessageNetwork.whatsapp.capabilities.createsGroup)
    XCTAssertTrue(MessageNetwork.signal.capabilities.createsGroup)
    XCTAssertFalse(MessageNetwork.instagram.capabilities.createsGroup)
    XCTAssertFalse(MessageNetwork.messenger.capabilities.createsGroup)
    XCTAssertFalse(MessageNetwork.iMessage.capabilities.createsGroup)
    XCTAssertFalse(MessageNetwork.selfNote.capabilities.createsGroup)
  }
}
