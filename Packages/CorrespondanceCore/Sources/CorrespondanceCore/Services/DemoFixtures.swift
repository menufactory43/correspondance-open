import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Les payloads `/sync` de démonstration — ceux qui servent déjà de fixtures
/// aux tests — et les médias qu'ils annoncent. Partagé par le Mac et l'iPhone :
/// ce qui s'affiche en démonstration sort du VRAI analyseur, appliqué aux
/// VRAIS payloads mautrix. Jamais de conversation réelle ici.
public enum DemoFixtures {
  public static let syncNames = ["matrix-sync-whatsapp", "matrix-sync-signal", "matrix-sync-instagram"]
  public static let selfUserID = "@meffysto:correspondance.local"

  /// Décode un payload du bundle, en ramenant ses horodatages à maintenant :
  /// une inbox datée de l'an dernier ne dit rien de la mise en page des heures.
  public static func response(named name: String, in bundle: Bundle = .main, now: Date = .now) -> MatrixSyncResponse? {
    guard let url = bundle.url(forResource: name, withExtension: "json"),
          let raw = try? String(contentsOf: url, encoding: .utf8),
          let data = shiftingTimestamps(in: raw, now: now).data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(MatrixSyncResponse.self, from: data)
  }

  /// Décale tous les `origin_server_ts` pour que le plus récent tombe il y a
  /// quelques minutes. Purement textuel : le payload reste un payload Matrix.
  public static func shiftingTimestamps(in json: String, now: Date = .now) -> String {
    let pattern = #""origin_server_ts"\s*:\s*(\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
    let full = NSRange(json.startIndex..., in: json)
    let matches = regex.matches(in: json, range: full)
    let values: [Int] = matches.compactMap {
      guard let range = Range($0.range(at: 1), in: json) else { return nil }
      return Int(json[range])
    }
    guard let newest = values.max() else { return json }
    let target = Int(now.addingTimeInterval(-8 * 60).timeIntervalSince1970 * 1000)
    let delta = target - newest
    var result = json
    for match in matches.reversed() {
      guard let whole = Range(match.range, in: result),
            let digits = Range(match.range(at: 1), in: result),
            let value = Int(result[digits])
      else { continue }
      result.replaceSubrange(whole, with: "\"origin_server_ts\": \(value + delta)")
    }
    return result
  }

  /// Dépose dans le cache des pièces jointes les médias que les payloads
  /// annoncent : sans fichier sous la main, une photo bridgée ne sait dire que
  /// « indisponible ». Des aplats de couleur, dessinés ici même.
  public static func seedAttachments() {
    let hues: [Double] = [0.09, 0.42, 0.55, 0.86]
    for (rank, hue) in hues.enumerated() {
      seedImage(
        mxc: "mxc://correspondance.local/demo-album-\(rank + 1)", type: .png,
        width: rank.isMultiple(of: 2) ? 480 : 640, height: rank.isMultiple(of: 2) ? 640 : 480, hue: hue
      )
    }
    seedImage(mxc: "mxc://correspondance.local/demo-reel-1", type: .jpeg, width: 540, height: 960, hue: 0.72)
    seedVoice(mxc: "mxc://correspondance.local/demo-vocal-1", seconds: 7)
  }

  private static func seedImage(mxc: String, type: UTType, width: Int, height: Int, hue: Double) {
    let contentType = type == .png ? "image/png" : "image/jpeg"
    guard MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: contentType) == nil,
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return }
    let (r1, g1, b1) = rgb(hue: hue, saturation: 0.34, brightness: 0.82)
    context.setFillColor(red: r1, green: g1, blue: b1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let (r2, g2, b2) = rgb(hue: hue, saturation: 0.55, brightness: 0.52)
    context.setFillColor(red: r2, green: g2, blue: b2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.38))
    guard let image = context.makeImage() else { return }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return }
    _ = MatrixAttachmentStore.store(data: data as Data, forMXC: mxc, contentType: contentType)
  }

  /// Un vrai WAV, parce que la bulle mesure sa durée avec AVFoundation.
  private static func seedVoice(mxc: String, seconds: Double) {
    guard MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: "audio/wav") == nil else { return }
    let rate = 16_000
    let count = Int(Double(rate) * seconds)
    var samples = Data(capacity: count * 2)
    for index in 0..<count {
      let t = Double(index) / Double(rate)
      let envelope = 0.35 * abs(sin(t * 1.7)) * (0.5 + 0.5 * sin(t * 0.6))
      let value = Int16(max(-1, min(1, sin(t * 2 * .pi * 220) * envelope)) * 32_000)
      withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
    }
    var wav = Data()
    func append(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
    append("fmt "); append32(16); append16(1); append16(1)
    append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
    append("data"); append32(UInt32(samples.count))
    wav.append(samples)
    _ = MatrixAttachmentStore.store(data: wav, forMXC: mxc, contentType: "audio/wav")
  }

  private static func rgb(hue: Double, saturation s: Double, brightness v: Double) -> (CGFloat, CGFloat, CGFloat) {
    let h = hue * 6
    let i = floor(h), f = h - i
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch Int(i) % 6 {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
  }
}
