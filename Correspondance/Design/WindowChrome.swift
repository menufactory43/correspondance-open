import AppKit
import SwiftUI

/// Ce que le système ne fournit pas encore : l'apparence claire/sombre suivant
/// le thème d'écriture, et le titre de fenêtre masqué (la barre d'outils native
/// et le fond de fenêtre viennent de `containerBackground`, plus de bricolage).
struct WindowChromeModifier: ViewModifier {
  let theme: WritingTheme

  func body(content: Content) -> some View {
    content
      .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
      .background(WindowChromeApplicator(isDark: theme.id.prefersDarkChrome))
  }
}

private struct WindowChromeApplicator: NSViewRepresentable {
  let isDark: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.postsFrameChangedNotifications = false
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let dark = isDark
    DispatchQueue.main.async {
      guard let window = nsView.window else { return }
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }
}

extension View {
  func correspondanceWindowChrome(_ theme: WritingTheme) -> some View {
    modifier(WindowChromeModifier(theme: theme))
  }
}

/// Bouton d’outil discret, style Apple / Claude.
struct SoftToolButton: View {
  let systemImage: String
  var title: String? = nil
  var helpText: String
  var isEmphasized: Bool = false
  var isDisabled: Bool = false
  let action: () -> Void

  @Environment(ThemePreferences.self) private var themes
  @State private var hovered = false

  private var theme: WritingTheme { themes.theme }

  private var foreground: Color {
    if isDisabled { return theme.inkTertiary.opacity(0.45) }
    if isEmphasized { return theme.accent }
    return theme.inkSecondary
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
        if let title {
          Text(title)
            .font(.system(size: 12, weight: isEmphasized ? .semibold : .medium))
        }
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, title == nil ? 0 : 8)
      .frame(minWidth: title == nil ? 28 : nil, minHeight: 28)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            hovered && !isDisabled
              ? theme.selection.opacity(0.85)
              : (isEmphasized ? theme.selection.opacity(0.55) : Color.clear)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(helpText)
    .accessibilityLabel(title ?? helpText)
    .onHover { hovered = $0 }
  }
}
