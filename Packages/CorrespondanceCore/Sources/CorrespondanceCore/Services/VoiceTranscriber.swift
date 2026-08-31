import Foundation
import Speech

/// Lire un message vocal plutôt que l'écouter.
///
/// `SFSpeechRecognizer` sur le fichier déjà téléchargé, **sur l'appareil**
/// quand il le peut (`supportsOnDeviceRecognition` — le modèle français est
/// téléchargé par le système à la première demande). C'est la règle de la
/// décision 7 tenue jusqu'au bout : le Relais ne lit pas les messages, et
/// Apple non plus si l'appareil sait s'en charger seul.
///
/// Le même code sur le Mac et sur l'iPhone : `Speech` existe des deux côtés.
public actor VoiceTranscriber {
  public static let shared = VoiceTranscriber()

  public enum Failure: LocalizedError, Equatable {
    case denied
    case unavailable
    case empty
    case failed(String)

    public var errorDescription: String? {
      switch self {
      case .denied: "La reconnaissance vocale est refusée. Réglages › Correspondance."
      case .unavailable: "La reconnaissance vocale n'est pas disponible pour le français ici."
      case .empty: "Rien de compréhensible dans ce message."
      case .failed(let reason): reason
      }
    }
  }

  /// Ce qu'on a déjà transcrit, par pièce jointe : une transcription coûte du
  /// temps et de la batterie, on ne la refait pas parce qu'une bulle a
  /// redessiné.
  private var cache: [String: String] = [:]

  public init() {}

  public func cached(_ attachmentID: String) -> String? { cache[attachmentID] }

  /// Demande l'autorisation, une fois. Rien ne part au réseau tant qu'elle
  /// n'est pas accordée — et rien du tout si la reconnaissance est locale.
  public static func requestPermission() async -> Bool {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .authorized { return true }
    if status == .denied || status == .restricted { return false }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { granted in
        continuation.resume(returning: granted == .authorized)
      }
    }
  }

  /// La transcription d'un message vocal déjà sur le disque.
  ///
  /// `locale` par défaut : le français, la langue dans laquelle on écrit ici.
  /// Le résultat est mis en cache sous l'identifiant de la pièce jointe.
  public func transcribe(
    attachmentID: String,
    fileURL: URL,
    locale: Locale = Locale(identifier: "fr-FR")
  ) async throws -> String {
    if let cached = cache[attachmentID] { return cached }
    guard await Self.requestPermission() else { throw Failure.denied }
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw Failure.unavailable
    }
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    // Sur l'appareil dès que possible : rien ne part chez Apple.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.shouldReportPartialResults = false

    let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      // `recognitionTask` rappelle plusieurs fois ; on ne reprend qu'une.
      let box = ResumeOnce(continuation)
      recognizer.recognitionTask(with: request) { result, error in
        if let error {
          box.resume(throwing: Failure.failed(error.localizedDescription))
          return
        }
        guard let result, result.isFinal else { return }
        box.resume(returning: result.bestTranscription.formattedString)
      }
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.empty }
    cache[attachmentID] = trimmed
    return trimmed
  }
}

/// `recognitionTask` peut rappeler après un premier résultat final ; reprendre
/// deux fois une continuation fait planter le processus. Cette petite boîte
/// garantit qu'on ne la reprend qu'une fois, quel que soit le nombre d'appels.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?

  init(_ continuation: CheckedContinuation<String, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: String) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: value)
  }

  func resume(throwing error: Error) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(throwing: error)
  }
}
