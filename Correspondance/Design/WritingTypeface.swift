import Foundation
import SwiftUI
import CorrespondanceCore

/// Familles d’écriture alignées sur iA Writer (OFL).
enum WritingTypeface: String, CaseIterable, Identifiable, Codable, Sendable {
  case quattro
  case duo
  case mono
  case plexSerif
  case plexSans
  case systemSerif

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .quattro: "iA Writer Quattro"
    case .duo: "iA Writer Duo"
    case .mono: "iA Writer Mono"
    case .plexSerif: "IBM Plex Serif"
    case .plexSans: "IBM Plex Sans"
    case .systemSerif: "New York"
    }
  }

  var subtitleFR: String {
    switch self {
    case .quattro: "La préférée — proportionnelle, lecture longue"
    case .duo: "Duospaced — rythme machine à écrire"
    case .mono: "Monospace — code / notes sèches"
    case .plexSerif: "Serif contemporain IBM"
    case .plexSans: "Sans lisible, UI claire"
    case .systemSerif: "Serif système Apple"
    }
  }

  var postScriptRegular: String {
    switch self {
    case .quattro: "iAWriterQuattroS-Regular"
    case .duo: "iAWriterDuoS-Regular"
    case .mono: "iAWriterMonoS-Regular"
    case .plexSerif: "IBMPlexSerif"
    case .plexSans: "IBMPlexSans"
    case .systemSerif: ""
    }
  }

  var postScriptItalic: String {
    switch self {
    case .quattro: "iAWriterQuattroS-Italic"
    case .duo: "iAWriterDuoS-Italic"
    case .mono: "iAWriterMonoS-Italic"
    case .plexSerif: "IBMPlexSerif-Italic"
    case .plexSans: "IBMPlexSans-Italic"
    case .systemSerif: ""
    }
  }

  /// SwiftUI font — tombe sur New York / system si la custom n’est pas chargée.
  func font(size: CGFloat, italic: Bool = false, weight: Font.Weight = .regular) -> Font {
    let name = italic ? postScriptItalic : postScriptRegular
    if !name.isEmpty {
      // weight custom fonts: iA Writer S n’a que Regular/Italic embarqués.
      return .custom(name, size: size)
    }
    if italic {
      return .system(size: size, weight: weight, design: .serif).italic()
    }
    return .system(size: size, weight: weight, design: .serif)
  }

  func nsFont(size: CGFloat, italic: Bool = false) -> PlatformFont {
    let name = italic ? postScriptItalic : postScriptRegular
    if !name.isEmpty, let font = PlatformFont(name: name, size: size) {
      return font
    }
    if let descriptor = PlatformFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
       let serif = PlatformFont.make(descriptor: descriptor, size: size)
    {
      return serif
    }
    return PlatformFont.systemFont(ofSize: size)
  }
}

enum FocusScope: String, CaseIterable, Identifiable, Codable, Sendable {
  case sentence
  case paragraph

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .sentence: "Phrase"
    case .paragraph: "Paragraphe"
    }
  }
}

enum LineLengthPreset: Int, CaseIterable, Identifiable, Codable, Sendable {
  case narrow = 64
  case classic = 72
  case wide = 80

  var id: Int { rawValue }

  var labelFR: String { "\(rawValue) car." }
}
