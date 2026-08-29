import AppKit
import AVFoundation
import Speech

/// Dictée → texte dans le champ. Micro / Speech, sinon dictée système.
@MainActor
@Observable
final class ComposerDictationController {
  private(set) var isListening = false

  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var engine: AVAudioEngine?
  private var baseText = ""
  private var apply: ((String) -> Void)?

  func toggle(currentText: String, apply: @escaping (String) -> Void) async {
    if isListening {
      stop()
      return
    }
    await start(currentText: currentText, apply: apply)
  }

  func stop() {
    request?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    request = nil
    if let engine {
      if engine.isRunning { engine.stop() }
      engine.inputNode.removeTap(onBus: 0)
    }
    engine = nil
    apply = nil
    isListening = false
  }

  private func start(currentText: String, apply: @escaping (String) -> Void) async {
    let allowed = await requestPermissions()
    guard allowed else {
      startSystemDictation()
      return
    }

    let recognizer = SFSpeechRecognizer(locale: .autoupdatingCurrent) ?? SFSpeechRecognizer()
    guard let recognizer, recognizer.isAvailable else {
      startSystemDictation()
      return
    }

    stop()
    self.recognizer = recognizer
    self.baseText = currentText
    self.apply = apply

    let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    recognitionRequest.shouldReportPartialResults = true
    recognitionRequest.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition {
      recognitionRequest.requiresOnDeviceRecognition = true
    }
    request = recognitionRequest

    let audioEngine = AVAudioEngine()
    engine = audioEngine
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      stop()
      startSystemDictation()
      return
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      recognitionRequest.append(buffer)
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      stop()
      startSystemDictation()
      return
    }

    isListening = true
    recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      Task { @MainActor in
        guard let self else { return }
        if let result {
          self.apply?(self.combined(result.bestTranscription.formattedString))
          if result.isFinal { self.stop() }
        }
        if error != nil, self.isListening {
          self.stop()
        }
      }
    }
  }

  private func combined(_ transcription: String) -> String {
    let snippet = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !snippet.isEmpty else { return baseText }
    if baseText.isEmpty { return snippet }
    if baseText.hasSuffix(" ") || baseText.hasSuffix("\n") {
      return baseText + snippet
    }
    return baseText + " " + snippet
  }

  private func startSystemDictation() {
    DispatchQueue.main.async {
      NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }
  }

  private func requestPermissions() async -> Bool {
    let speechOK = await requestSpeechAccess()
    let micOK = await requestMicrophoneAccess()
    return speechOK && micOK
  }

  private func requestSpeechAccess() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return true
    case .denied, .restricted: return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status == .authorized)
        }
      }
    @unknown default:
      return false
    }
  }

  private func requestMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .denied, .restricted: return false
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    @unknown default:
      return false
    }
  }
}
