import CoreText
import Foundation
import CorrespondanceCore

/// Préchauffe, hors du fil principal, ce que la première frame paierait sinon
/// comptant : les règles de `NSDataDetector` (et le chargement de
/// DataDetectorsCore qui va avec), puis la fonte d'écriture active.
///
/// Lancé dès l'init de l'app : les cœurs sont largement libres pendant que le
/// fil principal déroule AppKit, autant leur confier ce travail en parallèle.
/// Tout est idempotent et sans effet visible — au pire le warmup finit après
/// la première frame, et n'aura rien coûté.
enum LaunchWarmup {
  static func begin() {
    Task.detached(priority: .userInitiated) {
      // Une URL et un numéro : les deux familles de règles que compilent les bulles.
      _ = TextLinks.detect(in: "https://exemple.fr · 06 12 34 56 78")
    }
    Task.detached(priority: .userInitiated) {
      let face = ThemePreferences.storedTypeface()
      for name in [face.postScriptRegular, face.postScriptItalic] where !name.isEmpty {
        let font = CTFontCreateWithName(name as CFString, 15, nil)
        _ = CTFontCopyCharacterSet(font)
      }
    }
  }
}
