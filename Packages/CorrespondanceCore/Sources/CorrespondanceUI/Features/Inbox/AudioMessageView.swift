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

  @State private var player: AVPlayer?
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
  /// La transcription dépliée : un vocal de trois minutes fait une page.
  @State private var isTranscriptExpanded = false
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
        positionBar
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

  /// La barre de position, quelle que soit la source. Elle porte le
  /// glissement : **tous** les audios se cherchent, pas seulement ceux qui
  /// arrivent avec une onde. iMessage dépose des `.caf` nus, et sans onde la
  /// bulle n'offrait aucune prise — impossible de revenir en arrière sur le
  /// Mac.
  private var positionBar: some View {
    Group {
      if let voice = attachment.voice, !voice.waveform.isEmpty {
        waveform(voice)
      } else {
        plainBar
      }
    }
    .frame(width: Self.waveformWidth, height: 22, alignment: .leading)
    // La hauteur de prise dépasse celle du tracé — 22 pt de barres, c'est
    // trop mince pour un pouce, et 4 pt de filet encore moins pour un curseur.
    .contentShape(Rectangle().inset(by: -8))
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          isScrubbing = true
          preview(fraction: value.location.x / Self.waveformWidth)
        }
        .onEnded { value in
          preview(fraction: value.location.x / Self.waveformWidth)
          isScrubbing = false
          commitSeek(to: elapsed)
        }
    )
    // Sans souris ni doigt : deux gestes de VoiceOver, cinq secondes chacun.
    .accessibilityElement()
    .accessibilityLabel("Position dans le message audio")
    .accessibilityValue(timeLabel)
    .accessibilityAdjustableAction { direction in
      seek(by: direction == .increment ? 5 : -5)
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
  }

  /// Faute d'onde : un filet, dessiné à la main plutôt qu'un `ProgressView` —
  /// le style natif ne se laisse pas viser au doigt ni au curseur.
  private var plainBar: some View {
    let ink = isFromMe ? theme.bubbleOutInk : theme.accent
    return ZStack(alignment: .leading) {
      Capsule().fill(ink.opacity(0.32))
      Capsule().fill(ink).frame(width: max(2, Self.waveformWidth * fraction))
    }
    .frame(width: Self.waveformWidth, height: 4)
    .frame(height: 22)
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

  /// Viser un instant : le curseur suit le doigt sans toucher au lecteur.
  /// Rien ne bouge dans le son tant qu'on glisse — on ne fait que viser.
  private func preview(fraction target: Double) {
    guard duration > 0 else { return }
    elapsed = min(max(target, 0), 1) * duration
  }

  /// Poser la tête de lecture.
  ///
  /// `AVAudioPlayer.currentTime` ne se pose pas sur tout : sur les vocaux
  /// Signal, l'écrire ne déplaçait rien, et une pause suivie d'une reprise
  /// repartait du début. `AVPlayer.seek` cherche dans le flux décodé, tolérance
  /// nulle — la seule façon de tomber vraiment à l'instant visé, quel que soit
  /// le conteneur.
  private func commitSeek(to time: Double) {
    prepare()
    guard let player, duration > 0 else { return }
    let cible = min(max(time, 0), max(duration - 0.05, 0))
    elapsed = cible
    player.seek(
      to: CMTime(seconds: cible, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    if isPlaying { applyRate() }
  }

  private func seek(by seconds: Double) {
    commitSeek(to: elapsed + seconds)
  }

  private func applyRate() {
    player?.rate = Float(speed.rawValue)
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
      // Un vocal de trois minutes fait une page. On en montre le début — huit
      // lignes, jamais coupées au milieu d'une — et le reste se déplie sur
      // demande, dans le fil, sans fenêtre dans la fenêtre.
      VStack(alignment: .leading, spacing: 4) {
        Text(text)
          .font(Typography.meta(typeface))
          .foregroundStyle(isFromMe ? theme.bubbleOutInk.opacity(0.85) : theme.inkSecondary)
          .lineLimit(isTranscriptExpanded ? nil : 8)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if text.count > 300 {
          Button(isTranscriptExpanded ? "Replier" : "Tout lire") {
            isTranscriptExpanded.toggle()
          }
          .buttonStyle(.plain)
          .font(Typography.meta(typeface))
          .foregroundStyle(isFromMe ? theme.bubbleOutInk : theme.accent)
        }
      }
      .frame(maxWidth: 320, alignment: .leading)
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
    guard let url = attachment.resolvedFileURL else {
      failed = true
      return
    }
    let item = AVPlayerItem(url: url)
    let loaded = AVPlayer(playerItem: item)
    // Sans ça, une recherche à la fin d'un fichier fait tousser la lecture :
    // le lecteur attend un tampon plein avant de repartir.
    loaded.automaticallyWaitsToMinimizeStalling = false
    player = loaded
  }

  private func toggle() {
    prepare()
    guard let player else { return }
    if isPlaying {
      player.pause()
      isPlaying = false
      ticker?.cancel()
      Self.releasePlaybackSession()
      return
    }
    // Relire depuis le début quand la lecture précédente est allée au bout.
    if duration > 0, elapsed >= duration - 0.1 { commitSeek(to: 0) }
    isPlaying = true
    Self.claimPlaybackSession()
    player.play()
    applyRate()
    startTicker()
  }

  /// Une boucle `Task` plutôt qu'un `Timer` : elle reste sur l'acteur principal
  /// et s'annule proprement quand la bulle quitte l'écran. C'est elle aussi qui
  /// voit la fin du fichier — `AVPlayer` ne s'arrête pas, il reste posé dessus.
  private func startTicker() {
    ticker?.cancel()
    ticker = Task { @MainActor in
      while !Task.isCancelled, isPlaying, let player {
        let now = player.currentTime().seconds
        if !isScrubbing, now.isFinite { elapsed = now }
        if duration > 0, elapsed >= duration - 0.08 {
          player.pause()
          isPlaying = false
          elapsed = 0
          player.seek(to: .zero) { _ in }
          Self.releasePlaybackSession()
          return
        }
        try? await Task.sleep(for: .milliseconds(120))
      }
    }
  }

  private func stop() {
    ticker?.cancel()
    ticker = nil
    player?.pause()
    if isPlaying { Self.releasePlaybackSession() }
    isPlaying = false
  }

  /// La session audio de l'iPhone, prise pour LIRE. Sans ça, `AVPlayer`
  /// joue dans la catégorie par défaut, que l'interrupteur silencieux coupe :
  /// un vocal se lisait sans un son. Et après un enregistrement, la session
  /// restait en « playAndRecord », qui route vers l'écouteur — la voix sortait
  /// par le haut du téléphone, inaudible à bout de bras. Un vocal se lit
  /// comme un message : sur le haut-parleur, silencieux ou pas, et il baisse
  /// la musique le temps de parler. Hors de l'acteur principal : `setActive`
  /// attend le matériel.
  private static func claimPlaybackSession() {
    #if os(iOS)
    Task.detached(priority: .userInitiated) {
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try? session.setActive(true)
    }
    #endif
  }

  /// Rendre la session quand on a fini : la musique reprend son volume.
  private static func releasePlaybackSession() {
    #if os(iOS)
    Task.detached(priority: .utility) {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
  }

  public init(attachment: MessageAttachment, theme: WritingTheme, typeface: WritingTypeface = .quattro, isFromMe: Bool = false) {
    self.attachment = attachment
    self.theme = theme
    self.typeface = typeface
    self.isFromMe = isFromMe
  }
}
