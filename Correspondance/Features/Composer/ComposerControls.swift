import AppKit
import SwiftUI

enum ComposerTrailingAction: Equatable {
  case dictation
  case send

  static func resolve(canSend: Bool, isListening: Bool) -> Self {
    if isListening || !canSend { return .dictation }
    return .send
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
    case .send:
      ComposerCircleButton(
        systemImage: "arrow.up",
        helpText: "Envoyer",
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
        helpText: isListening ? "Arrêter la dictée" : "Dicter",
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
              Image(systemName: "doc")
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 56, height: 56)
                .background(theme.paperSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
}
