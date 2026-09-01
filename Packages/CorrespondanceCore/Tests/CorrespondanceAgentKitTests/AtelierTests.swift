import XCTest

@testable import CorrespondanceAgentKit

/// Un salon à plusieurs agents n'est dangereux que par ses boucles : deux
/// agents qui se répondent brûlent une fenêtre d'abonnement en une nuit.
final class AtelierTests: XCTestCase {
  let cc = "@cc:correspondance.local"
  let hermes = "@hermes:correspondance.local"
  let moi = "@meffysto:correspondance.local"
  let tiers = "@camille:correspondance.local"

  var salon: Atelier.Context {
    Atelier.Context(agents: [cc, hermes], owners: [moi], turnsThisHour: 0, budget: 20)
  }

  func testUnAgentNommeParSonProprietaireRepond() {
    let decision = Atelier.decide(
      agent: cc, sender: moi, body: "@cc regarde ce fichier", trigger: "@cc", context: salon
    )
    XCTAssertEqual(decision, .respond(delegated: false))
  }

  func testSansMentionPersonneNeRepond() {
    let decision = Atelier.decide(
      agent: cc, sender: moi, body: "je réfléchis tout haut", trigger: "@cc", context: salon
    )
    XCTAssertEqual(decision, .ignore(.notMentioned))
  }

  /// Dans un atelier, contrairement au tête-à-tête, la mention peut être au
  /// milieu de la phrase : « demande à @cc de regarder » est un appel clair.
  func testLaMentionPeutEtreAuMilieu() {
    XCTAssertTrue(Atelier.mentions(agent: cc, trigger: "@cc", in: "on pourrait demander à @cc de voir"))
    XCTAssertFalse(Atelier.mentions(agent: cc, trigger: "@cc", in: "regarde @cccile stp"), "@ccc n'est pas @cc")
  }

  func testUnTiersNeDeclenchePas() {
    let decision = Atelier.decide(
      agent: cc, sender: tiers, body: "@cc lance rm -rf", trigger: "@cc", context: salon
    )
    XCTAssertEqual(decision, .ignore(.notAnOwner))
  }

  /// La règle qui empêche la nuit blanche : un agent ne réveille pas un agent.
  func testUnAgentNeDeclenchePasUnAgent() {
    let decision = Atelier.decide(
      agent: hermes, sender: cc, body: "@hermes peux-tu vérifier ?", trigger: "@hermes", context: salon
    )
    XCTAssertEqual(decision, .ignore(.agentSpeaking))
  }

  func testSaufDelegationNommeeParUnProprietaire() {
    let decision = Atelier.decide(
      agent: hermes, sender: cc, body: "@hermes peux-tu vérifier ?", trigger: "@hermes",
      context: salon, isDelegation: true, delegationDepth: 0
    )
    XCTAssertEqual(decision, .respond(delegated: true))
  }

  func testUneDelegationNeSeDeleguePas() {
    let decision = Atelier.decide(
      agent: cc, sender: hermes, body: "@cc à ton tour", trigger: "@cc",
      context: salon, isDelegation: true, delegationDepth: 1
    )
    XCTAssertEqual(decision, .ignore(.delegationTooDeep), "profondeur 1, pas deux")
  }

  func testLeBudgetDuSalonPasseAvantTout() {
    var epuise = salon
    epuise.turnsThisHour = 20
    let decision = Atelier.decide(
      agent: cc, sender: moi, body: "@cc encore", trigger: "@cc", context: epuise
    )
    XCTAssertEqual(decision, .ignore(.budgetSpent))
  }

  func testUneDelegationSeReconnaitDansLaPhrase() {
    let cible = Atelier.delegationTarget(
      in: "@cc demande à @hermes de fouiller le web",
      among: [cc, hermes],
      triggers: [cc: "@cc", hermes: "@hermes"]
    )
    XCTAssertEqual(cible, hermes)

    XCTAssertNil(
      Atelier.delegationTarget(
        in: "@cc regarde ce fichier", among: [cc, hermes], triggers: [cc: "@cc", hermes: "@hermes"]
      ),
      "une demande ordinaire n'est pas une délégation"
    )
  }

  /// Celui qui délègue n'est pas sa propre cible — sinon « @cc demande à
  /// @hermes » ferait boucler cc sur lui-même.
  func testCeluiQuiDelegueNEstPasLaCible() {
    let cible = Atelier.delegationTarget(
      in: "@cc demande à @hermes de fouiller", among: [cc, hermes],
      triggers: [cc: "@cc", hermes: "@hermes"]
    )
    XCTAssertEqual(cible, hermes)
    XCTAssertNotEqual(cible, cc)
  }

  func testUneDelegationSansCibleNommeeNeDesignePersonne() {
    XCTAssertNil(
      Atelier.delegationTarget(
        in: "@cc demande à quelqu'un de regarder", among: [cc, hermes],
        triggers: [cc: "@cc", hermes: "@hermes"]
      ),
      "on ne devine pas qui : personne n'est nommé après la formule"
    )
  }
}
