import Foundation
import SwiftUI

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

public enum Platform {
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
