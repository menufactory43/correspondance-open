import AppKit
import SwiftUI

/// Aligne la barre de titre sur le thème et laisse le contenu
/// peindre sous les feux de circulation (transition sidebar continue).
struct WindowChromeModifier: ViewModifier {
  let theme: WritingTheme
  var sidebarVisible: Bool
  var zenMode: Bool

  func body(content: Content) -> some View {
    content
      .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
      .background(
        WindowChromeApplicator(
          theme: theme,
          sidebarVisible: sidebarVisible,
          zenMode: zenMode
        )
      )
  }
}

private struct WindowChromeApplicator: NSViewRepresentable {
  let theme: WritingTheme
  var sidebarVisible: Bool
  var zenMode: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.postsFrameChangedNotifications = false
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let sidebar = theme.sidebar
    let fill = zenMode ? theme.paper : theme.room
    let dark = theme.id.prefersDarkChrome
    let showSidebar = sidebarVisible

    DispatchQueue.main.async {
      guard let window = nsView.window else { return }

      if !window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.insert(.fullSizeContentView)
      }

      window.title = ""
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.isMovableByWindowBackground = true
      window.backgroundColor = NSColor(showSidebar ? sidebar : fill)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

      if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = .clear
      }
    }
  }
}

extension View {
  func correspondanceWindowChrome(
    _ theme: WritingTheme,
    sidebarVisible: Bool,
    zenMode: Bool = false
  ) -> some View {
    modifier(WindowChromeModifier(
      theme: theme,
      sidebarVisible: sidebarVisible,
      zenMode: zenMode
    ))
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
