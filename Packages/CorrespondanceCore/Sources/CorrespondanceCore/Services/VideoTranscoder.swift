// Sous Linux, pas d'AVFoundation : la vidéo part telle quelle.
#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Une vidéo de l'iPhone ou du Mac arrive en `.mov`, souvent HEVC. Les ponts
/// tranchent sur le type **avant** toute conversion : Signal et Slack n'ont
/// pas `video/quicktime` dans leur table (un `.MOV` revient en « unsupported
/// media type »), WhatsApp et Meta l'acceptent mais le réseau veut du H.264.
/// Le MP4 H.264/AAC passe partout — on le fabrique une fois, dans le
/// temporaire, avant que la pièce jointe parte. Le même code sert au Mac et
/// à l'iPhone : le `.MOV` refusé par Signal le 5 septembre venait du Mac,
/// qui ne convertissait pas.
public enum VideoTranscoder {
  /// Ce que le pont accepte tel quel : un MP4 déjà en H.264.
  public static func needsTranscoding(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard ["mov", "m4v", "mp4", "hevc", "avi", "mkv", "webm"].contains(ext) else { return false }
    return ext != "mp4"
  }

  /// Le fichier MP4, ou `nil` si l'export échoue : la pièce jointe part alors
  /// telle quelle, comme avant.
  public static func mp4(from path: String) async -> String? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      return nil
    }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).mp4")
    session.shouldOptimizeForNetworkUse = true
    do {
      try await session.export(to: destination, as: .mp4)
    } catch {
      return nil
    }
    return destination.path
  }

  /// Les mêmes chemins, les vidéos que le pont refuserait remplacées par leur
  /// MP4. L'ordre est gardé ; une conversion qui échoue laisse l'original.
  public static func settled(_ paths: [String]) async -> [String] {
    var out: [String] = []
    for path in paths {
      if needsTranscoding(path), let converted = await mp4(from: path) {
        out.append(converted)
      } else {
        out.append(path)
      }
    }
    return out
  }
}
#endif
