import AppKit
import SwiftUI

enum ComposerTrailingAction: Equatable {
  case dictation
  case send
  /// Le « plus tard » est posé : le même geste range le message au lieu de l'envoyer.
  case schedule

  static func resolve(canSend: Bool, isListening: Bool, isScheduling: Bool = false) -> Self {
    if isListening || !canSend { return .dictation }
    return isScheduling ? .schedule : .send
  }
}

enum ComposerMetrics {
  static let control: CGFloat = 32
  static let innerControl: CGFloat = 28
  static let bubbleMinHeight: CGFloat = 36
  static let bubbleCorner: CGFloat = 18
}

struct ComposerCircleButton: View {
  let systemImage: String
  var helpText: String
  var theme: WritingTheme
  var size: CGFloat = ComposerMetrics.control
  var iconSize: CGFloat = 16
  var isPrimary: Bool = false
  var isDisabled: Bool = false
  var isActive: Bool = false
  var showsProgress: Bool = false
  var symbolFillsControl: Bool = false
  let action: () -> Void

  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      ZStack {
        if showsProgress {
          ProgressView()
            .controlSize(.small)
            .tint(theme.paper)
        } else {
          Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: isPrimary ? .semibold : .medium))
            .symbolRenderingMode(symbolFillsControl ? .hierarchical : .monochrome)
            .foregroundStyle(foreground)
        }
      }
      .frame(width: size, height: size)
      .background(background)
      .contentShape(Circle())
    }
    .buttonStyle(ComposerPressStyle())
    .disabled(isDisabled)
    .help(helpText)
    .accessibilityLabel(helpText)
    .onHover { hovered = $0 }
  }

  private var foreground: Color {
    if isDisabled { return theme.inkTertiary.opacity(0.4) }
    if isPrimary { return theme.paper }
    if isActive { return theme.accent }
    if hovered { return theme.ink }
    return theme.inkSecondary
  }

  @ViewBuilder
  private var background: some View {
    if symbolFillsControl {
      Circle().fill(Color.clear)
    } else if isPrimary {
      Circle().fill(isDisabled ? theme.inkTertiary.opacity(0.18) : theme.accent)
    } else if isActive {
      Circle().fill(theme.accentSoft.opacity(0.55))
    } else if hovered && !isDisabled {
      Circle().fill(theme.selection.opacity(0.9))
    } else {
      Circle().fill(Color.clear)
    }
  }
}

struct ComposerPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct ComposerTrailingControl: View {
  var action: ComposerTrailingAction
  var theme: WritingTheme
  var isSending: Bool
  var canSend: Bool
  var isListening: Bool
  var onSend: () -> Void
  var onDictate: () -> Void

  var body: some View {
    switch action {
    case .send, .schedule:
      ComposerCircleButton(
        systemImage: action == .schedule ? "clock.badge.checkmark" : "arrow.up",
        helpText: action == .schedule ? "Programmer l’envoi" : "Envoyer",
        theme: theme,
        size: ComposerMetrics.innerControl,
        iconSize: 13,
        isPrimary: true,
        isDisabled: !canSend || isSending,
        showsProgress: isSending,
        action: onSend
      )
    case .dictation:
      ComposerCircleButton(
        systemImage: "mic.fill",
        helpText: isListening ? "Arrêter la dictée" : (DictusBridge.isActive ? "Dicter (Dictus)" : "Dicter"),
        theme: theme,
        size: ComposerMetrics.innerControl,
        iconSize: 13,
        isActive: isListening,
        action: onDictate
      )
      .accessibilityAddTraits(isListening ? .isSelected : [])
    }
  }
}

struct ComposerAttachmentStrip: View {
  @Binding var paths: [String]
  var theme: WritingTheme
  var horizontalPadding: CGFloat = 0

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
          ZStack(alignment: .topTrailing) {
            if let img = NSImage(contentsOfFile: path) {
              Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
              // Pas une image (PDF, son, archive…) : l'aperçu, c'est l'icône du
              // type et le nom du fichier — de quoi vérifier avant d'envoyer.
              VStack(spacing: 2) {
                Image(systemName: Self.symbol(forPath: path))
                  .font(.system(size: 16))
                  .foregroundStyle(theme.inkSecondary)
                Text(URL(fileURLWithPath: path).lastPathComponent)
                  .font(.system(size: 8))
                  .foregroundStyle(theme.inkTertiary)
                  .lineLimit(2)
                  .multilineTextAlignment(.center)
                  .padding(.horizontal, 3)
              }
              .frame(width: 56, height: 56)
              .background(theme.paperSecondary)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .help(path)
            }
            Button {
              paths.remove(at: index)
            } label: {
              Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Retirer la pièce jointe")
          }
        }
      }
      .padding(.horizontal, horizontalPadding)
    }
  }

  /// Icône du type de fichier, à l'extension.
  static func symbol(forPath path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "pdf": return "doc.richtext"
    case "mp4", "mov", "m4v": return "film"
    case "caf", "m4a", "mp3", "aac", "wav", "ogg", "opus": return "waveform"
    case "zip", "gz", "tar": return "doc.zipper"
    default: return "doc"
    }
  }
}

/// Le « + » du composer : un seul bouton, et un tiroir d'actions qui glisse
/// vers la droite quand on l'ouvre — la pilule de texte se resserre d'autant.
/// Le « + » pivote en « × » pour dire qu'il referme. Les entrées futures
/// (fichier, sondage…) viendront s'y ranger.
struct ComposerPlusTray: View {
  var theme: WritingTheme
  var isScheduling: Bool = false
  var iconSize: CGFloat = 28
  @Binding var isExpanded: Bool
  var onAttach: () -> Void
  /// `nil` là où « plus tard » n'a pas cours — une fenêtre détachée. Le tiroir
  /// n'ouvre alors qu'un seul bouton, plutôt qu'une horloge qui ne fait rien.
  var onSendLater: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let itemSpacing: CGFloat = 2
  private var offersSendLater: Bool { onSendLater != nil }
  /// La largeur du tiroir suit le nombre de boutons qu'il cache.
  private var trayWidth: CGFloat {
    offersSendLater
      ? ComposerMetrics.control * 2 + Self.itemSpacing
      : ComposerMetrics.control
  }
  /// Sans « plus tard », l'état « programmé » n'existe pas pour ce composer.
  private var showsScheduling: Bool { isScheduling && offersSendLater }
  private var spring: Animation? {
    reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.22)
  }

  var body: some View {
    HStack(spacing: 4) {
      ComposerCircleButton(
        systemImage: showsScheduling && !isExpanded ? "clock.circle.fill" : "plus.circle",
        helpText: isExpanded ? "Fermer" : "Options",
        theme: theme,
        iconSize: iconSize,
        isActive: showsScheduling,
        symbolFillsControl: true,
        action: toggle
      )
      .rotationEffect(.degrees(isExpanded ? 45 : 0))
      .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

      // Ancré à droite : en s'élargissant, le tiroir pousse ses boutons vers
      // la droite, comme s'ils sortaient de derrière le « + ».
      HStack(spacing: Self.itemSpacing) {
        ComposerCircleButton(
          systemImage: "photo",
          helpText: "Joindre une image",
          theme: theme,
          iconSize: 15,
          action: { choose(onAttach) }
        )
        if let onSendLater {
          ComposerCircleButton(
            systemImage: "clock",
            helpText: showsScheduling ? "Changer l’heure d’envoi (⌘⇧L)" : "Envoyer plus tard (⌘⇧L)",
            theme: theme,
            iconSize: 15,
            isActive: showsScheduling,
            action: { choose(onSendLater) }
          )
        }
      }
      .frame(width: isExpanded ? trayWidth : 0, alignment: .trailing)
      .clipped()
      .opacity(isExpanded ? 1 : 0)
      .allowsHitTesting(isExpanded)
      .accessibilityHidden(!isExpanded)
    }
    .animation(spring, value: isExpanded)
  }

  private func toggle() {
    isExpanded.toggle()
  }

  private func choose(_ action: @escaping () -> Void) {
    isExpanded = false
    action()
  }
}
