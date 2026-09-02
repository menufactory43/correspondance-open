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
    // Les résultats partiels ne servent pas à afficher : ils servent à **ne
    // rien perdre**. `Speech` découpe un fichier en énoncés et rend un résultat
    // final par énoncé ; en n'écoutant que `isFinal` on gardait le premier et
    // on jetait la suite — d'où des vocaux transcrits à moitié. On accumule
    // donc chaque énoncé clos, et l'hypothèse en cours si le dernier n'a jamais
    // été clos.
    request.shouldReportPartialResults = true
    if #available(macOS 13, iOS 16, *) { request.addsPunctuation = true }

    let collecteur = Collecteur()
    let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      collecteur.start(continuation)
      collecteur.task = recognizer.recognitionTask(with: request, delegate: collecteur)
    }
    withExtendedLifetime(collecteur) {}

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.empty }
    cache[attachmentID] = trimmed
    return trimmed
  }
}

/// Le ramasseur d'énoncés.
///
/// `Speech` rappelle plusieurs fois : une hypothèse à chaque avancée, un
/// résultat final à chaque énoncé clos, puis une fin de tâche. On garde tous
/// les énoncés dans l'ordre, plus l'hypothèse en cours si la fin arrive sans
/// l'avoir close, et on ne reprend la continuation qu'une seule fois — la
/// reprendre deux fois fait planter le processus.
private final class Collecteur: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var enonces: [String] = []
  private var encours = ""
  /// La tâche, gardée pour son `error` : le délégué ne le transporte pas.
  var task: SFSpeechRecognitionTask?

  func start(_ continuation: CheckedContinuation<String, Error>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
    lock.lock()
    encours = transcription.formattedString
    lock.unlock()
  }

  func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
    lock.lock()
    ajouter(result.bestTranscription.formattedString)
    encours = ""
    lock.unlock()
  }

  /// Ajoute un énoncé sans se répéter — **verrou déjà pris**.
  ///
  /// Selon les versions, `Speech` rend des énoncés successifs ou un texte
  /// cumulatif qui reprend tout depuis le début. Un texte qui commence par ce
  /// qu'on a déjà remplace ce qu'on a ; un texte déjà contenu est ignoré.
  private func ajouter(_ brut: String) {
    let texte = brut.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !texte.isEmpty else { return }
    let acquis = enonces.joined(separator: " ")
    if acquis.isEmpty { enonces = [texte]; return }
    if texte.hasPrefix(acquis) { enonces = [texte]; return }
    if acquis.hasSuffix(texte) || acquis.contains(texte) { return }
    enonces.append(texte)
  }

  func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
    lock.lock()
    ajouter(encours)
    encours = ""
    let texte = enonces.joined(separator: " ")
    let pending = continuation
    continuation = nil
    lock.unlock()
    guard let pending else { return }
    // Une erreur en cours de route ne doit pas effacer ce qui a déjà été
    // compris : un vocal à demi transcrit vaut mieux qu'un message d'échec.
    if !successfully, texte.isEmpty {
      let raison = task.error?.localizedDescription ?? self.task?.error?.localizedDescription
      pending.resume(throwing: VoiceTranscriber.Failure.failed(raison ?? "Transcription interrompue."))
      return
    }
    pending.resume(returning: texte)
  }
}
