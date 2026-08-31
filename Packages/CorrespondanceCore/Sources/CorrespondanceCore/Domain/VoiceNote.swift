import Foundation

/// Ce qui distingue un **message vocal** d'un fichier audio joint : quelqu'un a
/// tenu le micro et a parlé. Le fil le montre autrement — une forme d'onde, une
/// durée, et de quoi le lire sans l'écouter.
///
/// Matrix le dit en trois morceaux, tous posés par les ponts mautrix (v26.08)
/// sur un `m.audio` :
/// - `org.matrix.msc3245.voice: {}` — un objet vide dont la seule présence
///   signifie « vocal », et rien d'autre (MSC3245) ;
/// - `org.matrix.msc1767.audio: { duration, waveform }` — la durée en
///   millisecondes et la forme d'onde, 0…1024 par échantillon (MSC1767) ;
/// - `info.duration`, le repli quand le pont n'a pas posé le second.
public struct VoiceNote: Hashable, Codable, Sendable {
  /// Durée annoncée par l'expéditeur, en secondes. `0` quand personne ne l'a dite.
  public var duration: TimeInterval
  /// Forme d'onde normalisée entre 0 et 1, dans l'ordre du temps. Vide quand le
  /// réseau n'en envoie pas — la vue trace alors une barre simple.
  public var waveform: [Double]

  public init(duration: TimeInterval = 0, waveform: [Double] = []) {
    self.duration = duration
    self.waveform = waveform
  }

  /// L'échelle de MSC1767 : des entiers de 0 à 1024. On les ramène à 0…1 pour
  /// que la vue n'ait aucune arithmétique de protocole à connaître.
  public static let waveformScale: Double = 1024

  public static func normalized(_ raw: [Int]) -> [Double] {
    raw.map { min(max(Double($0) / waveformScale, 0), 1) }
  }

  /// Le chemin inverse, pour ce qu'on envoie nous-mêmes.
  public var encodedWaveform: [Int] {
    waveform.map { Int((min(max($0, 0), 1) * Self.waveformScale).rounded()) }
  }

  /// « 0:07 » — la durée telle que la bulle l'écrit.
  public var durationLabel: String {
    let total = Int(duration.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// Ramène la forme d'onde à un nombre de barres donné, en moyennant. Une
  /// forme d'onde WhatsApp fait parfois cent points ; une bulle en montre trente.
  public func bars(_ count: Int) -> [Double] {
    guard count > 0 else { return [] }
    guard !waveform.isEmpty else { return Array(repeating: 0.25, count: count) }
    guard waveform.count > count else {
      return waveform + Array(repeating: 0, count: count - waveform.count)
    }
    let width = Double(waveform.count) / Double(count)
    return (0..<count).map { index in
      let start = Int(Double(index) * width)
      let end = max(start + 1, Int(Double(index + 1) * width))
      let slice = waveform[start..<min(end, waveform.count)]
      return slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
    }
  }
}

public enum VoiceNoteKeys {
  /// Sa seule présence fait du `m.audio` un vocal (MSC3245).
  public static let voice = "org.matrix.msc3245.voice"
  /// Durée et forme d'onde (MSC1767).
  public static let audio = "org.matrix.msc1767.audio"
}
