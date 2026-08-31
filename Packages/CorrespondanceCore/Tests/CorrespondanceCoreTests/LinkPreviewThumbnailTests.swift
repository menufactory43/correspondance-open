import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CorrespondanceCore

/// Une vignette de carte ne pèse jamais plus que la carte : l'image livrée par
/// le pont peut faire des mégapixels, celle qu'on garde en mémoire non.
@MainActor
final class LinkPreviewThumbnailTests: XCTestCase {
  private func writePNG(width: Int, height: Int) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("apercu-\(UUID().uuidString).png")
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url.path
  }

  func testUneGrandeImageDeCarteEstReduiteALaTailleDeLaCarte() throws {
    let path = try writePNG(width: 2400, height: 1260)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let image = try XCTUnwrap(LinkPreviewStore.shared.thumbnail(atPath: path))
    let longest = max(image.size.width, image.size.height)
    XCTAssertLessThanOrEqual(longest, LinkPreviewStore.thumbnailMaxPixel)
    // Le rapport d'aspect tient : 2400 × 1260 → 720 × 378.
    XCTAssertEqual(image.size.width / image.size.height, 2400.0 / 1260.0, accuracy: 0.01)
  }

  func testUnePetiteImageResteTelleQuelle() throws {
    let path = try writePNG(width: 300, height: 200)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let image = try XCTUnwrap(LinkPreviewStore.shared.thumbnail(atPath: path))
    XCTAssertEqual(image.size.width, 300, accuracy: 1)
    XCTAssertEqual(image.size.height, 200, accuracy: 1)
  }
}
