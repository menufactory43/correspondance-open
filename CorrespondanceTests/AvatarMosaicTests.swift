import AppKit
import XCTest
@testable import Correspondance

/// La mosaïque d'un groupe sans photo. On ne juge pas ici de l'esthétique — seulement
/// du contrat : un PNG à la bonne définition, ou rien du tout quand il n'y a rien à montrer.
final class AvatarMosaicTests: XCTestCase {
  private func square(_ color: NSColor, side: CGFloat = 120) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    image.unlockFocus()
    return image
  }

  private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let rep = NSBitmapImageRep(data: data) else { return nil }
    return (rep.pixelsWide, rep.pixelsHigh)
  }

  func testMosaicIsRenderedAtTwiceTheLogicalSize() throws {
    for count in 2...4 {
      let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]
      let images = colors.prefix(count).map { square($0) }
      let data = try XCTUnwrap(
        AvatarMosaic.compose(Array(images), size: 44, separator: .white),
        "\(count) visages doivent composer une mosaïque"
      )
      XCTAssertFalse(data.isEmpty)
      let size = try XCTUnwrap(pixelSize(of: data))
      // 44 pt à 2× : la vignette doit rester nette dans les listes.
      XCTAssertEqual(size.width, 88)
      XCTAssertEqual(size.height, 88)
    }
  }

  /// Aucun visage : le fil garde ses initiales, la composition ne fabrique rien.
  func testNoImageGivesNoMosaic() {
    XCTAssertNil(AvatarMosaic.compose([], size: 44, separator: .white))
  }

  /// Un seul visage : le disque seul, pas de découpe inutile.
  func testASingleImageIsRenderedAlone() throws {
    let data = try XCTUnwrap(AvatarMosaic.compose([square(.systemPink)], size: 44, separator: .white))
    let size = try XCTUnwrap(pixelSize(of: data))
    XCTAssertEqual(size.width, 88)
    XCTAssertEqual(size.height, 88)
  }

  /// Au-delà de quatre, le modèle a déjà tranché ; la composition ne doit pas
  /// s'effondrer si on lui en passe plus quand même.
  func testMoreThanFourImagesStillCompose() throws {
    let images = (0..<6).map { _ in square(.systemTeal) }
    let data = try XCTUnwrap(AvatarMosaic.compose(images, size: 34, separator: .white))
    let size = try XCTUnwrap(pixelSize(of: data))
    XCTAssertEqual(size.width, 68)
    XCTAssertEqual(size.height, 68)
  }
}
