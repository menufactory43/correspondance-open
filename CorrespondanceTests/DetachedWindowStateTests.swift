import AppKit
import XCTest
import CorrespondanceCore
import CorrespondanceUI
@testable import Correspondance

/// Ce qu'une fenêtre détachée retient : sa place, et son épingle.
@MainActor
final class DetachedWindowStateTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "detached-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  /// La clé est celle du plan : un cadre par fil, nommé par le fil.
  func testFrameKeyNamesTheThread() {
    XCTAssertEqual(DetachedWindowState.frameKey(for: "signal:!abc"), "detached.frame.signal:!abc")
  }

  func testFrameSurvivesTheRoundTrip() {
    let frame = NSRect(x: 120, y: 340, width: 520, height: 640)
    DetachedWindowState.saveFrame(frame, for: "signal:1", in: defaults)
    XCTAssertEqual(DetachedWindowState.frame(for: "signal:1", in: defaults), frame)
  }

  /// Un post-it de 240 × 180 est un cadre comme un autre : il se retient.
  func testPostItFrameIsKept() {
    let frame = NSRect(x: 0, y: 0, width: 240, height: 180)
    DetachedWindowState.saveFrame(frame, for: "imessage:2", in: defaults)
    XCTAssertEqual(DetachedWindowState.frame(for: "imessage:2", in: defaults)?.size, frame.size)
  }

  /// Un fil jamais détaché n'a pas de place à lui : la fenêtre prend la taille
  /// par défaut plutôt qu'un cadre inventé.
  func testUnknownThreadHasNoFrame() {
    XCTAssertNil(DetachedWindowState.frame(for: "jamais-vu", in: defaults))
  }

  /// Un cadre illisible ou plat est un cadre absent — jamais une fenêtre à zéro pixel.
  func testDegenerateFramesAreIgnored() {
    DetachedWindowState.saveFrame(.zero, for: "plat", in: defaults)
    XCTAssertNil(DetachedWindowState.frame(for: "plat", in: defaults))

    defaults.set("pas un cadre", forKey: DetachedWindowState.frameKey(for: "abîmé"))
    XCTAssertNil(DetachedWindowState.frame(for: "abîmé", in: defaults))
  }

  func testForgettingAFrame() {
    DetachedWindowState.saveFrame(NSRect(x: 1, y: 2, width: 300, height: 300), for: "signal:1", in: defaults)
    DetachedWindowState.forgetFrame(for: "signal:1", in: defaults)
    XCTAssertNil(DetachedWindowState.frame(for: "signal:1", in: defaults))
  }

  /// L'épingle se retient par fil, et s'oublie quand on la retire.
  func testPinnedStateIsRememberedPerThread() {
    XCTAssertFalse(DetachedWindowState.isPinned("signal:1", in: defaults))
    DetachedWindowState.setPinned(true, for: "signal:1", in: defaults)
    XCTAssertTrue(DetachedWindowState.isPinned("signal:1", in: defaults))
    XCTAssertFalse(DetachedWindowState.isPinned("signal:2", in: defaults))
    DetachedWindowState.setPinned(false, for: "signal:1", in: defaults)
    XCTAssertFalse(DetachedWindowState.isPinned("signal:1", in: defaults))
  }

  /// « Ouvrir les notifications en fenêtre détachée » : éteint par défaut.
  func testNotificationsOpenDetachedIsOffByDefault() {
    XCTAssertFalse(DetachedWindowState.notificationsOpenDetached(in: defaults))
    DetachedWindowState.setNotificationsOpenDetached(true, in: defaults)
    XCTAssertTrue(DetachedWindowState.notificationsOpenDetached(in: defaults))
  }

  /// Les marges de la page suivent la largeur : larges en grande fenêtre,
  /// serrées en post-it, et jamais assez pour manger la page.
  func testPageMetricsShrinkWithTheWindow() {
    let large = FocusPageMetrics.resolve(width: 1100)
    XCTAssertEqual(large.leading, LayoutMetrics.pageLeading)
    XCTAssertFalse(large.isCompact)

    let moyenne = FocusPageMetrics.resolve(width: 520)
    XCTAssertLessThan(moyenne.leading, large.leading)
    XCTAssertGreaterThan(moyenne.leading, 12)

    let postIt = FocusPageMetrics.resolve(width: 240)
    XCTAssertTrue(postIt.isCompact)
    XCTAssertLessThanOrEqual(postIt.leading + postIt.trailing, 40)
    // Il reste de la page à lire, même au plus serré.
    XCTAssertGreaterThan(240 - postIt.leading - postIt.trailing, 180)
  }

  /// Les marges ne reculent jamais quand la fenêtre grandit.
  func testPageMetricsAreMonotonic() {
    var previous = FocusPageMetrics.resolve(width: 200).leading
    for width in stride(from: 220.0, through: 1200.0, by: 20.0) {
      let leading = FocusPageMetrics.resolve(width: width).leading
      XCTAssertGreaterThanOrEqual(leading, previous, "largeur \(width)")
      previous = leading
    }
  }
}
