import AVFoundation
import SwiftUI
import CorrespondanceCore

/// Lecteur inline d'un message audio, quel que soit le réseau : iMessage dépose
/// ses messages vocaux en `.caf`, Signal et WhatsApp en `.ogg` / `.m4a`.
///
/// Un bouton, une durée, une barre qui avance. Quand le réseau annonce un
/// **message vocal** (`org.matrix.msc3245.voice`), la barre devient la forme
/// d'onde de l'expéditeur, et un bouton propose de le **lire** plutôt que de
/// l'écouter : la transcription se fait sur l'appareil (`VoiceTranscriber`).
public struct AudioMessageView: View {
  public let attachment: MessageAttachment
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var isFromMe: Bool = false

  @State private var player: AVAudioPlayer?
  @State private var isPlaying = false
  @State private var elapsed: Double = 0
  @State private var duration: Double = 0
  @State private var failed = false
  @State private var ticker: Task<Void, Never>?
  @State private var transcript: String?
  @State private var isTranscribing = false
  @State private var transcriptError: String?
  /// Le glissement en cours sur l'onde : le ticker lui laisse la main.
  @State private var isScrubbing = false
  /// L'allure choisie vaut pour les vocaux suivants : on ne la repose pas à
  /// chaque bulle — c'est une préférence d'écoute, pas un réglage de message.
  @AppStorage("vocalPlaybackRate") private var storedRate: Double = 1

  /// La largeur de l'onde — et donc l'échelle du glissement.
  private static let waveformWidth: CGFloat = 140

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      controls
      transcriptLine
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(isFromMe ? theme.bubbleOut : theme.bubbleIn)
    )
    .task(id: attachment.id) {
      await loadDuration()
      transcript = await VoiceTranscriber.shared.cached(attachment.id)
    }
    .onDisappear(perform: stop)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Message \(attachment.isVoiceNote ? "vocal" : "audio"), \(timeLabel)")
  }

  private var speed: PlaybackSpeed { PlaybackSpeed(rawValue: storedRate) ?? .normale }

  private var controls: some View {
    HStack(spacing: 8) {
      Button(action: toggle) {
        Image(systemName: failed ? "exclamationmark.triangle" : (isPlaying ? "pause.fill" : "play.fill"))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isFromMe ? theme.bubbleOutInk : theme.accent)
          .frame(width: 24, height: 24)
          .background(Circle().fill(theme.paperSecondary.opacity(0.9)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(failed)
      .accessibilityLabel(isPlaying ? "Suspendre le message audio" : "Écouter le message audio")

      VStack(alignment: .leading, spacing: 3) {
        if let voice = attachment.voice, !voice.waveform.isEmpty {
          waveform(voice)
        } else {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(isFromMe ? theme.bubbleOutInk : theme.accent)
            .frame(width: Self.waveformWidth)
        }
        HStack(spacing: 6) {
          Text(failed ? "Audio illisible" : timeLabel)
            .font(Typography.meta(typeface))
            .foregroundStyle(isFromMe ? theme.bubbleOutInk.opacity(0.8) : theme.inkSecondary)
            .monospacedDigit()
          if !failed { speedButton }
        }
      }

      if attachment.isVoiceNote {
        transcriptButton
      }
    }
  }

  /// La forme d'onde de l'expéditeur, trente barres. Celles déjà écoutées
  /// portent l'encre pleine — c'est la progression, sans barre séparée.
  private func waveform(_ voice: VoiceNote) -> some View {
    let bars = voice.bars(30)
    return HStack(alignment: .center, spacing: 1.5) {
      ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
        let played = Double(index) / Double(max(bars.count - 1, 1)) <= fraction
        Capsule()
          .fill(
            (isFromMe ? theme.bubbleOutInk : theme.accent)
              .opacity(played ? 1 : 0.32)
          )
          .frame(width: 2, height: max(3, value * 22))
      }
    }
    .frame(width: Self.waveformWidth, height: 22, alignment: .leading)
    // L'onde EST la barre de position : on y pose le doigt et on cherche.
    // La hauteur de prise dépasse celle du tracé — 22 pt de barres, c'est
    // trop mince pour un pouce.
    .contentShape(Rectangle().inset(by: -8))
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          isScrubbing = true
          seek(toFraction: value.location.x / Self.waveformWidth)
        }
        .onEnded { _ in isScrubbing = false }
    )
    // Sans souris ni doigt : deux gestes de VoiceOver, cinq secondes chacun.
    .accessibilityElement()
    .accessibilityLabel("Position dans le message vocal")
    .accessibilityValue(timeLabel)
    .accessibilityAdjustableAction { direction in
      seek(by: direction == .increment ? 5 : -5)
    }
  }

  /// L'allure d'écoute, qui tourne : 1× → 1,5× → 2×.
  private var speedButton: some View {
    Button {
      storedRate = speed.next.rawValue
      applyRate()
    } label: {
      Text(speed.label)
        .font(Typography.meta(typeface))
        .monospacedDigit()
        // Pas de fondu enchaîné entre deux allures : « 1,5× » et « 2× » se
        // superposeraient le temps de la transition.
        .contentTransition(.identity)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          Capsule().fill((isFromMe ? theme.bubbleOutInk : theme.accent).opacity(0.16))
        )
        .foregroundStyle(isFromMe ? theme.bubbleOutInk : theme.accent)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Vitesse d'écoute : \(speed.label). Toucher pour changer.")
  }

  /// Viser un instant : le lecteur se monte si besoin, et l'affichage suit
  /// pendant qu'on glisse — sans attendre le prochain battement du ticker.
  private func seek(toFraction target: Double) {
    prepare()
    guard let player, player.duration > 0 else { return }
    let time = min(max(target, 0), 1) * player.duration
    player.currentTime = time
    elapsed = time
  }

  private func seek(by seconds: Double) {
    prepare()
    guard let player, player.duration > 0 else { return }
    seek(toFraction: (player.currentTime + seconds) / player.duration)
  }

  private func applyRate() {
    guard let player else { return }
    player.enableRate = true
    player.rate = Float(speed.rawValue)
  }

  /// « Lire » : la transcription, sur l'appareil quand il sait le faire.
  private var transcriptButton: some View {
    Button {
      Task { await transcribe() }
    } label: {
      Group {
        if isTranscribing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: transcript == nil ? "text.bubble" : "text.bubble.fill")
            .font(.system(size: 12, weight: .medium))
        }
      }
      .foregroundStyle(isFromMe ? theme.bubbleOutInk.opacity(0.8) : theme.inkSecondary)
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isTranscribing || attachment.resolvedFileURL == nil)
    .accessibilityLabel(transcript == nil ? "Transcrire le message vocal" : "Masquer la transcription")
  }

  @ViewBuilder
  private var transcriptLine: some View {
    if let text = transcript ?? transcriptError {
      Text(text)
        .font(Typography.meta(typeface))
        .foregroundStyle(isFromMe ? theme.bubbleOutInk.opacity(0.85) : theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 210, alignment: .leading)
        .textSelection(.enabled)
        .transition(.opacity)
    }
  }

  private func transcribe() async {
    guard !isTranscribing else { return }
    // Retaper le bouton referme la transcription : on ne relit pas deux fois.
    if transcript != nil {
      transcript = nil
      return
    }
    guard let url = attachment.resolvedFileURL else { return }
    isTranscribing = true
    transcriptError = nil
    defer { isTranscribing = false }
    do {
      transcript = try await VoiceTranscriber.shared.transcribe(attachmentID: attachment.id, fileURL: url)
    } catch {
      transcriptError = (error as? VoiceTranscriber.Failure)?.errorDescription ?? error.localizedDescription
    }
  }

  private var fraction: Double {
    guard duration > 0 else { return 0 }
    return min(max(elapsed / duration, 0), 1)
  }

  private var timeLabel: String {
    let shown = isPlaying || elapsed > 0 ? elapsed : duration
    let total = Int(shown.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// La durée seule, hors du fil principal. Monter un `AVAudioPlayer` réveille
  /// mediaserverd et alloue une file audio : réservé au premier appui sur Lecture,
  /// pas à l'apparition de la bulle — un fil rouvert au lancement en compte plusieurs.
  private func loadDuration() async {
    guard player == nil, duration == 0, !failed else { return }
    guard let url = attachment.resolvedFileURL else {
      failed = true
      return
    }
    let seconds = await Task.detached(priority: .utility) { () -> Double? in
      guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
      let value = CMTimeGetSeconds(time)
      return value.isFinite ? value : nil
    }.value
    guard !Task.isCancelled, player == nil else { return }
    if let seconds {
      duration = seconds
    } else {
      failed = true
    }
  }

  private func prepare() {
    guard player == nil, !failed else { return }
    guard let url = attachment.resolvedFileURL,
          let loaded = try? AVAudioPlayer(contentsOf: url)
    else {
      failed = true
      return
    }
    loaded.enableRate = true
    loaded.prepareToPlay()
    player = loaded
    duration = loaded.duration
  }

  private func toggle() {
    prepare()
    guard let player else { return }
    if player.isPlaying {
      player.pause()
      isPlaying = false
      ticker?.cancel()
      return
    }
    // Relire depuis le début quand la lecture précédente est allée au bout.
    if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
    applyRate()
    player.play()
    isPlaying = true
    startTicker()
  }

  /// Une boucle `Task` plutôt qu'un `Timer` : elle reste sur l'acteur principal
  /// et s'annule proprement quand la bulle quitte l'écran.
  private func startTicker() {
    ticker?.cancel()
    ticker = Task { @MainActor in
      while !Task.isCancelled, let player, player.isPlaying {
        if !isScrubbing { elapsed = player.currentTime }
        try? await Task.sleep(for: .milliseconds(120))
      }
      guard !Task.isCancelled else { return }
      if player?.isPlaying != true {
        isPlaying = false
        elapsed = 0
      }
    }
  }

  private func stop() {
    ticker?.cancel()
    ticker = nil
    player?.stop()
    isPlaying = false
  }

  public init(attachment: MessageAttachment, theme: WritingTheme, typeface: WritingTypeface = .quattro, isFromMe: Bool = false) {
    self.attachment = attachment
    self.theme = theme
    self.typeface = typeface
    self.isFromMe = isFromMe
  }
}
