import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Une vidéo dans le fil : sa première image, un triangle de lecture et sa
/// durée. Un clic l'ouvre dans une fenêtre de l'app — pas dans QuickTime.
struct AttachmentVideoView: View {
  let url: URL
  var maxWidth: CGFloat
  var maxHeight: CGFloat
  var cornerRadius: CGFloat = 12
  var placeholder: Color
  var border: Color?
  var label: String

  @State private var poster: VideoPosterStore.Poster?
  @State private var isHovering = false

  private var fitted: CGSize {
    // Tant que l'affiche n'est pas connue, on tient la place d'une vidéo de
    // téléphone filmée à l'horizontale.
    let size = poster?.size ?? CGSize(width: 16, height: 9)
    let scale = min(maxWidth / size.width, maxHeight / size.height, 1000)
    return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }

  init(
    url: URL,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    cornerRadius: CGFloat = 12,
    placeholder: Color,
    border: Color? = nil,
    label: String
  ) {
    self.url = url
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.cornerRadius = cornerRadius
    self.placeholder = placeholder
    self.border = border
    self.label = label
    _poster = State(initialValue: VideoPosterStore.shared.cached(for: url))
  }

  var body: some View {
    ZStack {
      if let poster {
        Image(nsImage: poster.image)
          .resizable()
      } else {
        placeholder
      }
      playGlyph
      if let duration = poster?.durationLabel {
        Text(duration)
          .font(Typography.meta.monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.black.opacity(0.55), in: Capsule())
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(8)
      }
    }
    .frame(width: fitted.width, height: fitted.height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      if let border {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(border, lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .onHover { isHovering = $0 }
    .onTapGesture { VideoPlayerWindow.open(url: url, title: label) }
    .help("Lire la vidéo")
    .accessibilityLabel("Vidéo : \(label)")
    .accessibilityAddTraits(.isButton)
    .task(id: url) {
      guard poster == nil else { return }
      poster = await VideoPosterStore.shared.poster(for: url)
    }
  }

  private var playGlyph: some View {
    Image(systemName: "play.fill")
      .font(.system(size: 22, weight: .semibold))
      .foregroundStyle(.white)
      .padding(16)
      .background(.black.opacity(isHovering ? 0.7 : 0.5), in: Circle())
      .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
      .scaleEffect(isHovering ? 1.06 : 1)
      .animation(.easeOut(duration: 0.15), value: isHovering)
  }
}

/// Première image et durée des vidéos, gardées en mémoire : le fil défile sans
/// rouvrir le fichier à chaque recomposition.
@MainActor
final class VideoPosterStore {
  static let shared = VideoPosterStore()

  struct Poster {
    let image: NSImage
    let size: CGSize
    let duration: TimeInterval

    var durationLabel: String {
      let total = Int(duration.rounded())
      let minutes = total / 60
      let seconds = total % 60
      return minutes >= 60
        ? String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        : String(format: "%d:%02d", minutes, seconds)
    }
  }

  private var cache: [String: Poster] = [:]
  private var inFlight: [String: Task<Poster?, Never>] = [:]

  private static func key(_ url: URL) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return "\(url.path)|\(size)"
  }

  func cached(for url: URL) -> Poster? {
    cache[Self.key(url)]
  }

  func poster(for url: URL) async -> Poster? {
    let key = Self.key(url)
    if let hit = cache[key] { return hit }
    if let task = inFlight[key] { return await task.value }
    let task = Task.detached(priority: .userInitiated) { await Self.generate(url: url) }
    inFlight[key] = task
    let poster = await task.value
    inFlight[key] = nil
    if let poster { cache[key] = poster }
    return poster
  }

  private nonisolated static func generate(url: URL) async -> Poster? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1200, height: 1200)
    // Pas l'image zéro — souvent noire — mais pas trop loin non plus.
    let seconds = min(0.5, max(0, CMTimeGetSeconds(duration) / 4))
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
    let size = CGSize(width: cgImage.width, height: cgImage.height)
    return Poster(
      image: NSImage(cgImage: cgImage, size: size),
      size: size,
      duration: CMTimeGetSeconds(duration)
    )
  }
}

/// Une fenêtre par vidéo ouverte ; rouvrir la même la ramène au premier plan.
@MainActor
enum VideoPlayerWindow {
  private static var windows: [URL: NSWindow] = [:]
  private static var players: [URL: AVPlayer] = [:]

  static func open(url: URL, title: String) {
    if let existing = windows[url] {
      existing.makeKeyAndOrderFront(nil)
      players[url]?.play()
      return
    }
    let player = AVPlayer(url: url)
    let host = NSHostingController(rootView: PlayerScreen(player: player))
    let window = NSWindow(contentViewController: host)
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.setContentSize(initialSize(for: url))
    window.center()
    windows[url] = window
    players[url] = player
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { _ in
      Task { @MainActor in
        players[url]?.pause()
        players[url] = nil
        windows[url] = nil
      }
    }
    window.makeKeyAndOrderFront(nil)
    player.play()
  }

  /// La fenêtre s'ouvre à la taille de la vidéo, bornée à l'écran.
  private static func initialSize(for url: URL) -> NSSize {
    let natural = VideoPosterStore.shared.cached(for: url)?.size ?? CGSize(width: 960, height: 540)
    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    let scale = min(screen.width * 0.8 / natural.width, screen.height * 0.8 / natural.height, 1)
    return NSSize(width: max(480, natural.width * scale), height: max(270, natural.height * scale))
  }

  private struct PlayerScreen: View {
    let player: AVPlayer

    var body: some View {
      VideoPlayer(player: player)
        .frame(minWidth: 480, minHeight: 270)
        .background(Color.black)
        .ignoresSafeArea()
    }
  }
}
