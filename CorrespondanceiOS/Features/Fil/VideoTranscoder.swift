import AVFoundation
import Foundation

/// Une vidéo de l'iPhone arrive en `.mov`, souvent HEVC : les ponts la
/// refusent (« Message not bridged »). Le réseau veut un MP4 H.264/AAC — on
/// le fabrique une fois, dans le temporaire, avant que la pièce jointe parte.
enum VideoTranscoder {
  /// Ce que le pont accepte tel quel : un MP4 déjà en H.264.
  static func needsTranscoding(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard ["mov", "m4v", "mp4", "hevc", "avi", "mkv", "webm"].contains(ext) else { return false }
    return ext != "mp4"
  }

  /// Le fichier MP4, ou `nil` si l'export échoue : la pièce jointe part alors
  /// telle quelle, comme avant.
  static func mp4(from path: String) async -> String? {
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
}
