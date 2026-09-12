import XCTest
@testable import CorrespondanceTerminal

final class LineEditorTests: XCTestCase {
  func testInsertAndBackspaceKeepGraphemesWhole() {
    var editor = LineEditor("salut ")
    editor.insert("👩‍👩‍👧")
    XCTAssertEqual(editor.cursor, 7)
    editor.backspace()
    XCTAssertEqual(editor.text, "salut ")
  }

  func testWordMotionsAndDeletion() {
    var editor = LineEditor("bonjour tout le monde")
    editor.moveWordLeft()
    XCTAssertEqual(editor.cursor, 16)
    editor.deleteWordBackward()
    XCTAssertEqual(editor.text, "bonjour tout monde")
    editor.moveToLineStart()
    editor.moveWordRight()
    XCTAssertEqual(editor.cursor, 7)
  }

  func testKillLine() {
    var editor = LineEditor("ligne un\nligne deux", allowsNewlines: true)
    editor.deleteToLineStart()
    XCTAssertEqual(editor.text, "ligne un\n")
    editor.deleteToLineStart()
    XCTAssertEqual(editor.text, "ligne un")
  }

  func testSingleLineEditorFlattensNewlines() {
    var editor = LineEditor()
    editor.insert("a\nb")
    XCTAssertEqual(editor.text, "a b")
  }

  func testVerticalMovementAcrossWrappedLines() {
    var editor = LineEditor("abcdef ghijkl", allowsNewlines: true)
    // Largeur 7 : « abcdef » / « ghijkl ». Le curseur est au bout.
    XCTAssertTrue(editor.moveVertically(by: -1, width: 7))
    XCTAssertEqual(editor.cursor, 6)
    XCTAssertFalse(editor.moveVertically(by: -1, width: 7))
  }

  func testCursorPosition() {
    let editor = LineEditor("日本語", allowsNewlines: true)
    let position = editor.cursorPosition(width: 20)
    XCTAssertEqual(position.row, 0)
    XCTAssertEqual(position.column, 6)
  }

  func testShiftEnterInsertsNewlineButEnterDoesNot() {
    var editor = LineEditor(allowsNewlines: true)
    XCTAssertTrue(editor.handle(KeyEvent(.enter, .shift)))
    XCTAssertEqual(editor.text, "\n")
    XCTAssertFalse(editor.handle(KeyEvent(.enter)))
  }
}
