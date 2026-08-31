import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

// Le seul fichier de Core où `#if os` est légitime : il existe pour que plus aucun
// autre n'en ait besoin. Un symbole AppKit qui a un jumeau UIKit se traduit ici,
// une fois, et les vues partagées ne connaissent plus que le nom neutre.

#if canImport(AppKit)
  public typealias PlatformImage = NSImage
  public typealias PlatformColor = NSColor
  public typealias PlatformFont = NSFont
  public typealias PlatformFontDescriptor = NSFontDescriptor
#else
  public typealias PlatformImage = UIImage
  public typealias PlatformColor = UIColor
  public typealias PlatformFont = UIFont
  public typealias PlatformFontDescriptor = UIFontDescriptor
#endif

extension Image {
  /// `Image(nsImage:)` sur Mac, `Image(uiImage:)` sur iPhone.
  public init(platformImage: PlatformImage) {
    #if canImport(AppKit)
      self.init(nsImage: platformImage)
    #else
      self.init(uiImage: platformImage)
    #endif
  }
}

extension PlatformFont {
  /// `NSFont(descriptor:size:)` est faillible, `UIFont(descriptor:size:)` ne l'est pas.
  public static func make(descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont? {
    #if canImport(AppKit)
      return NSFont(descriptor: descriptor, size: size)
    #else
      return UIFont(descriptor: descriptor, size: size)
    #endif
  }
}

#if canImport(AppKit)
  extension NSImage {
    /// `UIImage.pngData()` existe déjà ; NSImage passe par une représentation bitmap.
    public func pngData() -> Data? {
      guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
      return rep.representation(using: .png, properties: [:])
    }
  }
#endif

extension PlatformColor {
  /// `NSColor` sait changer d'espace colorimétrique, `UIColor` non — et n'en a pas besoin.
  public var deviceRGBCGColor: CGColor {
    #if canImport(AppKit)
      return usingColorSpace(.deviceRGB)?.cgColor ?? cgColor
    #else
      return cgColor
    #endif
  }

  /// Le fond de fenêtre du système : ce qui sépare deux visages d'une mosaïque.
  public static var platformWindowBackground: PlatformColor {
    #if canImport(AppKit)
      return .windowBackgroundColor
    #else
      return .systemBackground
    #endif
  }
}

extension PlatformImage {
  /// Emballe un bitmap CoreGraphics dans l'image de la plateforme.
  public static func from(cgImage: CGImage) -> PlatformImage {
    #if canImport(AppKit)
      return NSImage(
        cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    #else
      return UIImage(cgImage: cgImage)
    #endif
  }

  /// `NSImage` choisit sa représentation selon le cadre visé ; `UIImage` en a une seule.
  public func cgImage(fitting rect: CGRect) -> CGImage? {
    #if canImport(AppKit)
      var proposed = rect
      return cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    #else
      return cgImage
    #endif
  }
}

extension CGImage {
  /// Encodage PNG sans passer par `NSBitmapImageRep` : ImageIO existe des deux côtés.
  public func pngData() -> Data? {
    let buffer = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        buffer, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, self, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return buffer as Data
  }
}

extension NSValue {
  /// `NSValue(size:)` côté AppKit, `NSValue(cgSize:)` côté UIKit — même boîte.
  public static func platformSize(_ size: CGSize) -> NSValue {
    #if canImport(AppKit)
      return NSValue(size: size)
    #else
      return NSValue(cgSize: size)
    #endif
  }

  public var platformSizeValue: CGSize {
    #if canImport(AppKit)
      return sizeValue
    #else
      return cgSizeValue
    #endif
  }
}

public enum Platform {
  /// Le nom que cet appareil donne à sa session Matrix (`/login`).
  /// Le Relais liste les sessions : « Correspondance (Mac) » et
  /// « Correspondance (iPhone) » doivent s'y distinguer.
  public static var deviceDisplayName: String {
    #if canImport(AppKit)
      return "Correspondance (Mac)"
    #else
      return "Correspondance (iPhone)"
    #endif
  }

  /// Ouvre une URL dans l'app qui la revendique.
  @discardableResult
  public static func open(_ url: URL) -> Bool {
    #if canImport(AppKit)
      return NSWorkspace.shared.open(url)
    #else
      Task { @MainActor in UIApplication.shared.open(url) }
      return true
    #endif
  }

  /// Met du texte dans le presse-papiers du système.
  public static func copyToPasteboard(_ string: String) {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    #else
      Task { @MainActor in UIPasteboard.general.string = string }
    #endif
  }
}
