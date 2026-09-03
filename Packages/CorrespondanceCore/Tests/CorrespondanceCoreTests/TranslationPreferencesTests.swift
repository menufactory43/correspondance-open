import XCTest
@testable import CorrespondanceCore

/// Les réglages de traduction d'un fil, locaux à l'appareil.
final class TranslationPreferencesTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "correspondance.tests.translation.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testNothingByDefault() {
    let prefs = TranslationPreferences(defaults: defaults)
    XCTAssertNil(prefs.incomingTarget(for: "imessage:julia"))
    XCTAssertNil(prefs.outgoingTarget(for: "imessage:julia"))
  }

  func testIncomingAndOutgoingAreIndependentAndPerConversation() {
    let prefs = TranslationPreferences(defaults: defaults)
    prefs.setIncomingTarget("fr", for: "imessage:julia")
    prefs.setOutgoingTarget("pt", for: "imessage:julia")
    XCTAssertEqual(prefs.incomingTarget(for: "imessage:julia"), "fr")
    XCTAssertEqual(prefs.outgoingTarget(for: "imessage:julia"), "pt")
    XCTAssertNil(prefs.incomingTarget(for: "imessage:camille"))
    XCTAssertNil(prefs.outgoingTarget(for: "imessage:camille"))
  }

  /// `nil` et la chaîne vide (ce qu'écrit un `Picker` sur « Non ») effacent.
  func testClearing() {
    let prefs = TranslationPreferences(defaults: defaults)
    prefs.setIncomingTarget("fr", for: "c")
    prefs.setIncomingTarget(nil, for: "c")
    XCTAssertNil(prefs.incomingTarget(for: "c"))
    XCTAssertNil(defaults.object(forKey: TranslationPreferences.incomingKey("c")))

    prefs.setOutgoingTarget("pt", for: "c")
    prefs.setOutgoingTarget("", for: "c")
    XCTAssertNil(prefs.outgoingTarget(for: "c"))
    XCTAssertNil(defaults.object(forKey: TranslationPreferences.outgoingKey("c")))
  }

  /// Les clés sont celles que `@AppStorage` lit dans les vues.
  func testKeys() {
    XCTAssertEqual(TranslationPreferences.incomingKey("x"), "correspondance.translate.incoming.x")
    XCTAssertEqual(TranslationPreferences.outgoingKey("x"), "correspondance.translate.outgoing.x")
    defaults.set("es", forKey: "correspondance.translate.incoming.x")
    XCTAssertEqual(TranslationPreferences(defaults: defaults).incomingTarget(for: "x"), "es")
  }

  func testLanguageNamesAndCodes() {
    XCTAssertEqual(TranslationPreferences.Language.named("pt-BR"), .portuguese)
    XCTAssertEqual(TranslationPreferences.Language.named("zh-Hant"), .chinese)
    XCTAssertNil(TranslationPreferences.Language.named("nl"))
    XCTAssertEqual(TranslationPreferences.enFR("pt"), "en portugais")
    XCTAssertEqual(TranslationPreferences.enFR("nl"), "en nl")
    XCTAssertEqual(TranslationPreferences.Language.allCases.count, 8)
  }
}
