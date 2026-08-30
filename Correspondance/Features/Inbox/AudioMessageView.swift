import AVFoundation
import AppKit
import SwiftUI

/// Lecteur inline d'un message audio, quel que soit le réseau : iMessage dépose
/// ses messages vocaux en `.caf`, Signal et WhatsApp en `.ogg` / `.m4a`.
///
/// Pas de sélecteur ni de forme d'onde : un bouton, une durée, une barre qui
/// avance — ce que Messages montre quand on n'a pas encore écouté.
struct AudioMessageView: View {
  let attachment: MessageAttachment
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var isFromMe: Bool = false

  @State private var player: AVAudioPlayer?
  @State private var isPlaying = false
  @State private var elapsed: Double = 0
  @State private var duration: Double = 0
  @State private var failed = false
  @State private var ticker: Task<Void, Never>?

  var body: some View {
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
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .tint(isFromMe ? theme.bubbleOutInk : theme.accent)
          .frame(width: 140)
        Text(failed ? "Audio illisible" : timeLabel)
          .font(Typography.meta(typeface))
          .foregroundStyle(isFromMe ? theme.bubbleOutInk.opacity(0.8) : theme.inkSecondary)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(isFromMe ? theme.bubbleOut : theme.bubbleIn)
    )
    .task(id: attachment.id) { await loadDuration() }
    .onDisappear(perform: stop)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Message audio, \(timeLabel)")
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
        elapsed = player.currentTime
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
}
