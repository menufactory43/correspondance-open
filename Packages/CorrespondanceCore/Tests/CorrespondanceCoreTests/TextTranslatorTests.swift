#if canImport(NaturalLanguage)
import XCTest
@testable import CorrespondanceCore

/// La traduction comme réflexe de l'appareil : reconnaître la langue sans se
/// tromper, et ne jamais traduire deux fois la même bulle.
final class TextTranslatorTests: XCTestCase {
  func testDetectsFrenchAndPortuguese() {
    XCTAssertEqual(TextTranslator.language(of: "On dit 19 h 30 devant le cinéma ?"), "fr")
    XCTAssertEqual(TextTranslator.language(of: "Oi meffysto! Tudo bem?"), "pt")
    XCTAssertEqual(
      TextTranslator.language(of: "A gente se vê no domingo? Minha mãe também vem, ela não come carne."),
      "pt"
    )
    XCTAssertEqual(TextTranslator.language(of: "Hello, how are you doing today?"), "en")
  }

  /// Un mot, un emoji, un nombre : on ne se prononce pas.
  func testShortOrLetterlessTextIsNotDetected() {
    XCTAssertNil(TextTranslator.language(of: "Carrément."))
    XCTAssertNil(TextTranslator.language(of: "ok 👍"))
    XCTAssertNil(TextTranslator.language(of: "   "))
    XCTAssertNil(TextTranslator.language(of: "0612345678 — 19:30"))
    XCTAssertNil(TextTranslator.language(of: "🥪🍎🍎🍎🍎🍎🍎🍎🍎🍎🍎🍎🍎"))
  }

  /// La langue de l'appareil ne vaut pas un bouton « Traduire ».
  func testForeignLanguageIgnoresDeviceLanguage() {
    let device = TextTranslator.deviceLanguage
    let sample = device == "pt"
      ? "On dit 19 h 30 devant le cinéma ?"
      : "A gente se vê no domingo? Minha mãe também vem."
    XCTAssertNotNil(TextTranslator.foreignLanguage(of: sample))
    if device == "fr" {
      XCTAssertNil(TextTranslator.foreignLanguage(of: "Tu as vu la bande-annonce du film de jeudi ?"))
    }
  }

  func testBaseLanguageMergesRegionsButKeepsChineseScripts() {
    XCTAssertTrue(TextTranslator.sameLanguage("pt-BR", "pt"))
    XCTAssertTrue(TextTranslator.sameLanguage("FR", "fr-CA"))
    XCTAssertFalse(TextTranslator.sameLanguage("zh-Hans", "zh-Hant"))
    XCTAssertFalse(TextTranslator.sameLanguage("es", "pt"))
  }

  /// Le moteur n'est appelé qu'une fois par message et par langue cible.
  func testTranslateCachesByMessageAndTarget() async throws {
    let translator = TextTranslator()
    let calls = Compteur()
    let engine: @MainActor (String) async throws -> String = { text in
      calls.increment()
      return "[\(text)]"
    }
    let first = try await translator.translate(messageID: "m1", text: "Oi meffysto! Tudo bem?", to: "fr", using: engine)
    XCTAssertEqual(first, "[Oi meffysto! Tudo bem?]")
    let again = try await translator.translate(messageID: "m1", text: "Oi meffysto! Tudo bem?", to: "fr-FR", using: engine)
    XCTAssertEqual(again, first)
    XCTAssertEqual(calls.value, 1, "la même bulle vers la même langue ne repasse pas au moteur")

    let cached = await translator.cached(messageID: "m1", target: "fr")
    XCTAssertEqual(cached, first)

    _ = try await translator.translate(messageID: "m1", text: "Oi meffysto! Tudo bem?", to: "en", using: engine)
    XCTAssertEqual(calls.value, 2, "une autre langue cible est une autre traduction")

    await translator.forget(messageID: "m1")
    let forgotten = await translator.cached(messageID: "m1", target: "fr")
    XCTAssertNil(forgotten)
  }

  func testEmptyTextThrows() async {
    let translator = TextTranslator()
    do {
      _ = try await translator.translate(messageID: "m2", text: "  ", to: "fr") { $0 }
      XCTFail("un texte vide ne se traduit pas")
    } catch {
      XCTAssertEqual(error as? TextTranslator.Failure, .empty)
    }
  }

  func testStoreMakesCachedAvailable() async {
    let translator = TextTranslator()
    await translator.store(messageID: "m3", target: "fr", translation: "Salut meffysto ! Ça va ?")
    let cached = await translator.cached(messageID: "m3", target: "fr")
    XCTAssertEqual(cached, "Salut meffysto ! Ça va ?")
  }
}

private final class Compteur: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
#endif
