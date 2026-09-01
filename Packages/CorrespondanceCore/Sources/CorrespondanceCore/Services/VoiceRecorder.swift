import AVFoundation
import Foundation

/// L'enregistrement d'un message vocal — le même sur le Mac et sur l'iPhone.
///
/// `AVAudioRecorder` en AAC dans un `.m4a` : c'est ce que le matériel encode
/// sans effort. Le fichier ne part pas tel quel — `OggOpusEncoder` le mue en
/// Ogg/Opus, seul format que les trois ponts acceptent. La forme d'onde se
/// relève pendant qu'on parle (`updateMeters`), pas après :
/// c'est ce qui la rend gratuite, et fidèle à ce qu'on a entendu.
///
/// La session audio n'existe que sur iOS ; sur macOS, l'autorisation micro
/// suffit. Rien ici ne connaît SwiftUI : la vue observe `level` et `duration`.
@MainActor
@Observable
public final class VoiceRecorder {
  public enum State: Equatable {
    case idle
    case recording
    /// Le micro a été refusé, ou l'enregistrement n'a pas démarré.
    case failed(String)
  }

  public private(set) var state: State = .idle
  /// Niveau instantané, 0…1 — ce qui fait bouger la barre pendant qu'on parle.
  public private(set) var level: Double = 0
  public private(set) var duration: TimeInterval = 0
  /// Les niveaux relevés depuis le début : la forme d'onde qu'on enverra.
  public private(set) var samples: [Double] = []

  private var recorder: AVAudioRecorder?
  private var ticker: Task<Void, Never>?
  private var fileURL: URL?

  public init() {}

  public var isRecording: Bool { state == .recording }

  /// Un vocal d'une seconde est un doigt qui a glissé, pas un message.
  public static let minimumDuration: TimeInterval = 0.6

  /// Le micro est-il DÉJÀ accordé ? La vue le demande avant de laisser tenir :
  /// l'alerte système, si elle paraît pendant un maintien, annule le toucher.
  public static var hasPermission: Bool {
    AVAudioApplication.shared.recordPermission == .granted
  }

  /// Le micro est-il accordé ? Demande l'autorisation la première fois.
  public static func requestPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  /// Démarre l'enregistrement. Rend `false` si le micro est refusé — la vue
  /// n'a alors rien à faire de plus, l'état porte déjà le message.
  @discardableResult
  public func start() async -> Bool {
    guard state != .recording else { return true }
    guard await Self.requestPermission() else {
      state = .failed("Le micro est refusé. Réglages › Correspondance › Micro.")
      return false
    }
    #if os(iOS)
    // HORS de l'acteur principal : sur un appareil sans entrée audio — un
    // simulateur — `setActive` peut rester une demi-minute sans rendre la
    // main, et c'est toute l'interface qui s'arrête avec lui.
    let ready = await Task.detached(priority: .userInitiated) { () -> Bool in
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
        return true
      } catch {
        return false
      }
    }.value
    guard ready else {
      state = .failed("Le micro n'a pas pu démarrer.")
      return false
    }
    #endif

    let url = Self.newFileURL()
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]
    // Monter le magnétophone hors de l'acteur principal, pour la même raison
    // que la session : `record()` attend le matériel.
    let started = await Task.detached(priority: .userInitiated) { () -> Started? in
      guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return nil }
      recorder.isMeteringEnabled = true
      guard recorder.record() else { return nil }
      return Started(recorder: recorder)
    }.value
    guard let started else {
      state = .failed("Le micro n'a pas pu démarrer.")
      return false
    }
    recorder = started.recorder
    fileURL = url
    samples = []
    duration = 0
    state = .recording
    startTicker()
    return true
  }

  /// `AVAudioRecorder` n'est pas `Sendable` ; il ne quitte pourtant ce fil que
  /// pour être rangé ici, et personne d'autre ne le touche entre-temps.
  private struct Started: @unchecked Sendable {
    let recorder: AVAudioRecorder
  }

  /// Arrête et rend le fichier avec sa forme d'onde. `nil` si l'enregistrement
  /// est trop court pour être un message, ou s'il n'a jamais démarré.
  public func stop() -> (url: URL, voice: VoiceNote)? {
    ticker?.cancel()
    ticker = nil
    guard let recorder, let fileURL else {
      state = .idle
      return nil
    }
    let seconds = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    deactivateSession()
    state = .idle
    let relevés = samples
    samples = []
    duration = 0
    level = 0
    guard seconds >= Self.minimumDuration else {
      try? FileManager.default.removeItem(at: fileURL)
      self.fileURL = nil
      return nil
    }
    self.fileURL = nil
    return (fileURL, VoiceNote(duration: seconds, waveform: relevés))
  }

  /// Abandonne : le fichier part avec le geste.
  public func cancel() {
    ticker?.cancel()
    ticker = nil
    recorder?.stop()
    recorder = nil
    deactivateSession()
    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    fileURL = nil
    samples = []
    duration = 0
    level = 0
    state = .idle
  }

  private func deactivateSession() {
    #if os(iOS)
    // Comme l'activation : rendre la session peut attendre le matériel.
    Task.detached(priority: .utility) {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
  }

  /// Vingt relevés par seconde : assez pour une barre vivante, assez peu pour
  /// qu'une minute de parole tienne en douze cents points.
  private func startTicker() {
    ticker?.cancel()
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled, let self, let recorder = self.recorder, recorder.isRecording {
        recorder.updateMeters()
        let value = Self.normalized(decibels: Double(recorder.averagePower(forChannel: 0)))
        self.level = value
        self.samples.append(value)
        self.duration = recorder.currentTime
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// Les décibels d'`AVAudioRecorder` vont de -160 à 0. On les rabat sur 0…1
  /// avec un plancher à -50 : en dessous, c'est le silence de la pièce.
  public nonisolated static func normalized(decibels: Double) -> Double {
    guard decibels.isFinite else { return 0 }
    let floorDB = -50.0
    guard decibels > floorDB else { return 0 }
    return min(max((decibels - floorDB) / -floorDB, 0), 1)
  }

  private static func newFileURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocaux", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(UUID().uuidString).m4a")
  }
}
