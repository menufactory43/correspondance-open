import XCTest
@testable import CorrespondanceTerminal

final class CellWidthTests: XCTestCase {
  func testASCIIAndAccents() {
    XCTAssertEqual(CellWidth.of("hello"), 5)
    XCTAssertEqual(CellWidth.of("été"), 3)
    XCTAssertEqual(CellWidth.of("e\u{301}"), 1) // e + accent combinant
  }

  func testWideAndEmoji() {
    XCTAssertEqual(CellWidth.of("日本"), 4)
    XCTAssertEqual(CellWidth.of("👍"), 2)
    XCTAssertEqual(CellWidth.of("❤️"), 2) // cœur + VS16
    XCTAssertEqual(CellWidth.of("🇫🇷"), 2)
    XCTAssertEqual(CellWidth.of("👩‍👩‍👧"), 2)
    XCTAssertEqual(CellWidth.of("👍🏽"), 2)
  }

  func testPlaceholderIsOneCell() {
    let cell = KittyGraphics.placeholder(id: 0x123456, row: 3, column: 250)
    XCTAssertEqual(cell.grapheme.count, 1, "le placeholder doit rester un seul graphème")
    XCTAssertEqual(CellWidth.of(Character(cell.grapheme)), 1)
    XCTAssertEqual(cell.style.foreground, .rgb(0x12, 0x34, 0x56))
  }
}

final class TextLayoutTests: XCTestCase {
  func testWrapsAtSpaces() {
    let lines = TextLayout.wrap("le chat dort sur le canapé", width: 10).map(\.text)
    XCTAssertEqual(lines, ["le chat", "dort sur", "le canapé"])
  }

  func testHardBreaksLongWords() {
    let lines = TextLayout.wrap("https://exemple.fr/abcdef", width: 10).map(\.text)
    XCTAssertEqual(lines, ["https://ex", "emple.fr/a", "bcdef"])
  }

  func testKeepsParagraphsAndEmptyLines() {
    let lines = TextLayout.wrap("a\n\nb", width: 10).map(\.text)
    XCTAssertEqual(lines, ["a", "", "b"])
  }

  func testWideCharactersNeverOverflow() {
    for line in TextLayout.wrap("日本語のテキストです", width: 5) {
      XCTAssertLessThanOrEqual(line.width, 5)
    }
  }

  func testTruncate() {
    XCTAssertEqual(TextLayout.truncate("bonjour tout le monde", to: 8), "bonjour…")
    XCTAssertEqual(TextLayout.truncate("court", to: 8), "court")
  }

  func testOffsetsPointIntoSource() {
    let text = "un deux trois"
    for line in TextLayout.wrap(text, width: 6) where !line.text.isEmpty {
      let start = text.index(text.startIndex, offsetBy: line.startOffset)
      XCTAssertTrue(text[start...].hasPrefix(line.text), "\(line)")
    }
  }
}

final class InputParserTests: XCTestCase {
  private func parse(_ string: String) -> [InputEvent] {
    var parser = InputParser()
    return parser.feed(Array(string.utf8))
  }

  func testPlainAndControl() {
    XCTAssertEqual(parse("a\u{03}\r"), [.key(.char("a")), .key(.control("c")), .key(KeyEvent(.enter))])
  }

  func testArrowsWithModifiers() {
    XCTAssertEqual(parse("\u{1B}[A\u{1B}[1;5C"), [.key(KeyEvent(.up)), .key(KeyEvent(.right, .control))])
  }

  func testKittyProtocol() {
    XCTAssertEqual(parse("\u{1B}[13;2u"), [.key(KeyEvent(.enter, .shift))])
    XCTAssertEqual(parse("\u{1B}[27u"), [.key(KeyEvent(.escape))])
    XCTAssertEqual(parse("\u{1B}[99;5u"), [.key(.control("c"))])
    XCTAssertEqual(parse("\u{1B}[?1u"), [.keyboardProtocolFlags(1)])
  }

  func testUTF8Split() {
    var parser = InputParser()
    let bytes = Array("é".utf8)
    XCTAssertEqual(parser.feed([bytes[0]]), [])
    XCTAssertEqual(parser.feed([bytes[1]]), [.key(.char("é"))])
  }

  func testBracketedPasteAcrossReads() {
    var parser = InputParser()
    XCTAssertEqual(parser.feed(Array("\u{1B}[200~bon".utf8)), [])
    XCTAssertEqual(parser.feed(Array("jour\n\u{1B}[20".utf8)), [])
    XCTAssertEqual(parser.feed(Array("1~x".utf8)), [.paste("bonjour\n"), .key(.char("x"))])
  }

  func testMouse() {
    XCTAssertEqual(parse("\u{1B}[<64;10;5M"), [.mouse(MouseEvent(kind: .scrollUp, x: 9, y: 4, modifiers: []))])
    XCTAssertEqual(parse("\u{1B}[<0;3;2m"), [.mouse(MouseEvent(kind: .release(button: 0), x: 2, y: 1, modifiers: []))])
  }

  func testLoneEscapeWaits() {
    var parser = InputParser()
    XCTAssertEqual(parser.feed([0x1B]), [])
    XCTAssertTrue(parser.hasLoneEscape)
    XCTAssertEqual(parser.flushLoneEscape(), [.key(KeyEvent(.escape))])
  }

  func testAltKey() {
    XCTAssertEqual(parse("\u{1B}b"), [.key(KeyEvent(.character("b"), .alt))])
  }

  func testGraphicsReplyAndDA1() {
    XCTAssertEqual(parse("\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[?62;22c"), [.graphicsReply(id: 31, message: "OK"), .primaryDeviceAttributes])
  }

  func testFocusAndCellSize() {
    XCTAssertEqual(parse("\u{1B}[I\u{1B}[6;20;10t"), [.focus(true), .cellPixelSize(width: 10, height: 20)])
  }
}

final class RendererTests: XCTestCase {
  func testSecondIdenticalFrameWritesNothing() {
    var renderer = Renderer()
    var canvas = Canvas(width: 20, height: 3)
    canvas.put("bonjour", x: 0, y: 0, style: .plain)
    XCTAssertFalse(renderer.render(canvas).isEmpty)
    XCTAssertTrue(renderer.render(canvas).isEmpty)
  }

  func testOnlyChangedCellsAreWritten() {
    var renderer = Renderer()
    renderer.synchronizedOutput = false
    var canvas = Canvas(width: 20, height: 3)
    canvas.put("bonjour", x: 0, y: 1, style: .plain)
    _ = renderer.render(canvas)
    canvas.put("J", x: 3, y: 1, style: .plain)
    let output = String(decoding: renderer.render(canvas), as: UTF8.self)
    XCTAssertEqual(output, "\u{1B}[?25l\u{1B}[2;4HJ")
  }

  func testStyleIsEmittedOncePerRun() {
    var renderer = Renderer()
    renderer.synchronizedOutput = false
    var canvas = Canvas(width: 10, height: 1)
    _ = renderer.render(canvas)
    canvas.put("abc", x: 0, y: 0, style: Style(foreground: .red, attributes: .bold))
    let output = String(decoding: renderer.render(canvas), as: UTF8.self)
    XCTAssertEqual(output, "\u{1B}[?25l\u{1B}[1;1H\u{1B}[1;31mabc\u{1B}[0m")
  }

  func testWideCharacterClippedAtEdge() {
    var canvas = Canvas(width: 3, height: 1)
    canvas.put("ab日", x: 0, y: 0, style: .plain)
    XCTAssertEqual(canvas.cells.map(\.grapheme), ["a", "b", " "])
  }

  func testOverwritingHalfOfWideCharacter() {
    var canvas = Canvas(width: 4, height: 1)
    canvas.put("日", x: 0, y: 0, style: .plain)
    canvas.put("x", x: 1, y: 0, style: .plain)
    XCTAssertEqual(canvas.cells.map(\.grapheme), [" ", "x", " ", " "])
  }
}
