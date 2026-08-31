import XCTest
@testable import CorrespondanceCore

final class OneTimeCodeTests: XCTestCase {
  func testUnGroupeDeQuatreAHuitChiffresEstUnCode() {
    XCTAssertTrue(OneTimeCode.looksLikeCode("8421"))
    XCTAssertTrue(OneTimeCode.looksLikeCode("Votre code : 493028"))
    XCTAssertTrue(OneTimeCode.looksLikeCode("12345678"))
  }

  func testLesMotsClesSuffisentSansChiffre() {
    XCTAssertTrue(OneTimeCode.looksLikeCode("Ton code de vérification arrive"))
    XCTAssertTrue(OneTimeCode.looksLikeCode("verification code sent"))
    XCTAssertTrue(OneTimeCode.looksLikeCode("Authentification à deux facteurs"))
  }

  /// Dix chiffres, c'est un numéro de téléphone ; deux, une heure ; et un
  /// groupe collé à des lettres, une référence.
  func testCeQuiNEstPasUnCode() {
    XCTAssertFalse(OneTimeCode.looksLikeCode("0612345678"))
    XCTAssertFalse(OneTimeCode.looksLikeCode("On se voit à 18h"))
    XCTAssertFalse(OneTimeCode.looksLikeCode("Salle 1024b au fond"))
    XCTAssertFalse(OneTimeCode.looksLikeCode("Bonne journée !"))
    XCTAssertFalse(OneTimeCode.looksLikeCode(""))
  }
}

final class NotificationGroupingTests: XCTestCase {
  private let fil = "whatsapp:!abc:relais"
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func testUnPremierMessageOuvreSaRafale() {
    let burst = NotificationGrouping.extend(nil, conversationID: fil, at: t0, isUrgent: false, sequence: 1)
    XCTAssertEqual(burst.count, 1)
    XCTAssertEqual(burst.key, "\(fil)#1")
  }

  func testSixMessagesEnDixSecondesNeFontQuUneNotification() {
    var burst = NotificationGrouping.extend(nil, conversationID: fil, at: t0, isUrgent: false, sequence: 1)
    for index in 1...5 {
      burst = NotificationGrouping.extend(
        burst, conversationID: fil, at: t0.addingTimeInterval(Double(index) * 2),
        isUrgent: false, sequence: 2
      )
    }
    XCTAssertEqual(burst.count, 6)
    // Même identifiant : la dernière notification REMPLACE les précédentes.
    XCTAssertEqual(burst.key, "\(fil)#1")
  }

  func testPasseQuinzeSecondesCEstUneAutrePriseDeParole() {
    let first = NotificationGrouping.extend(nil, conversationID: fil, at: t0, isUrgent: false, sequence: 1)
    let later = NotificationGrouping.extend(
      first, conversationID: fil, at: t0.addingTimeInterval(16), isUrgent: false, sequence: 2
    )
    XCTAssertEqual(later.count, 1)
    XCTAssertEqual(later.key, "\(fil)#2")
  }

  /// Un code vaut trente secondes : il n'attend pas la fin d'une rafale.
  func testUnCodeOuvreToujoursSaPropreNotification() {
    let burst = NotificationGrouping.extend(nil, conversationID: fil, at: t0, isUrgent: false, sequence: 1)
    let urgent = NotificationGrouping.extend(
      burst, conversationID: fil, at: t0.addingTimeInterval(1), isUrgent: true, sequence: 2
    )
    XCTAssertEqual(urgent.count, 1)
    XCTAssertEqual(urgent.key, "\(fil)#2")
  }

  func testLeCorpsDitCeQuIlCache() {
    XCTAssertEqual(NotificationGrouping.bodyFR(latest: "à demain", count: 1), "à demain")
    XCTAssertEqual(NotificationGrouping.bodyFR(latest: "à demain", count: 2), "à demain\net 1 autre message")
    XCTAssertEqual(NotificationGrouping.bodyFR(latest: "à demain", count: 4), "à demain\net 3 autres messages")
  }
}
