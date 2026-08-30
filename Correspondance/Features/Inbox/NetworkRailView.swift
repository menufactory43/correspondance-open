import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Rail vertical à gauche de la liste : Tous + un bouton par réseau branché.
/// Les réseaux futurs (Instagram, Messenger) apparaîtront d'eux-mêmes dès
/// qu'ils existeront dans `MessageNetwork` — rien à câbler ici.
struct NetworkRailView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState

  @Namespace private var selectionNamespace

  private var theme: WritingTheme { themes.theme }

  /// `nil` = « Tous », puis l'ordre de déclaration de l'enum.
  static var slots: [MessageNetwork?] { [nil] + MessageNetwork.allCases }

  var body: some View {
    VStack(spacing: 6) {
      ForEach(Array(Self.slots.enumerated()), id: \.offset) { index, network in
        railButton(network, shortcutIndex: index + 1)
      }
      Spacer(minLength: 0)
      // Ce qui attend de partir — le dossier « Send Later » de Beeper, au bas du rail.
      scheduledButton
    }
    .padding(.vertical, Spacing.xs)
    .frame(width: RailMetrics.width)
    .frame(maxHeight: .infinity)
    // Le rail se creuse d'un cran dans la sidebar, sans jamais s'en détacher :
    // même matériau, même continuité verticale, y compris sous la barre de titre.
    .background { theme.rail.opacity(0.5).ignoresSafeArea() }
    .opacity(controlActiveState == .inactive ? 0.55 : 1)
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: controlActiveState)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Réseaux")
  }

  private func railButton(_ network: MessageNetwork?, shortcutIndex: Int) -> some View {
    let isSelected = store.networkFilter == network
    let unread = store.unreadCount(for: network)
    let label = network?.labelFR ?? "Tous"

    return Button {
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
        store.setNetworkFilter(network)
      }
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: network?.systemImage ?? "tray.full")
          .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.accent : theme.inkSecondary)
          .frame(width: RailMetrics.item, height: RailMetrics.item)
          .background(alignment: .center) {
            if isSelected {
              selectionBackground
            }
          }

        if unread > 0 {
          RailUnreadBadge(count: unread, theme: theme)
            .offset(x: 4, y: -2)
        }
      }
      .frame(width: RailMetrics.width - 8, height: RailMetrics.item)
      .contentShape(Rectangle())
    }
    .buttonStyle(ComposerPressStyle())
    .help("\(label) (⌘\(shortcutIndex))")
    .accessibilityLabel(unread > 0 ? "\(label), \(unread) non lus" : label)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var scheduledButton: some View {
    let isSelected = store.isShowingScheduled
    let count = store.scheduledMessages.count
    let failed = store.scheduledMessages.contains { $0.lastError != nil }

    return Button {
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
        store.setShowingScheduled(!isSelected)
      }
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: failed ? "clock.badge.exclamationmark" : "clock")
          .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.accent : theme.inkSecondary)
          .frame(width: RailMetrics.item, height: RailMetrics.item)
          .background(alignment: .center) {
            if isSelected {
              selectionBackground
            }
          }
        if count > 0 {
          RailUnreadBadge(count: count, theme: theme)
            .offset(x: 4, y: -2)
        }
      }
      .frame(width: RailMetrics.width - 8, height: RailMetrics.item)
      .contentShape(Rectangle())
    }
    .buttonStyle(ComposerPressStyle())
    .help("Messages programmés")
    .accessibilityLabel(count == 0 ? "Messages programmés" : "\(count) message\(count > 1 ? "s" : "") programmé\(count > 1 ? "s" : "")")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  @ViewBuilder
  private var selectionBackground: some View {
    Color.clear
      .glassSurface(
        cornerRadius: 10,
        tint: theme.accent.opacity(0.22),
        fallbackFill: theme.selection,
        border: theme.edge,
        isInteractive: true
      )
      .matchedGeometryEffect(id: "railSelection", in: selectionNamespace)
  }
}

enum RailMetrics {
  static let width: CGFloat = 52
  static let item: CGFloat = 34
}

private struct RailUnreadBadge: View {
  let count: Int
  let theme: WritingTheme

  var body: some View {
    Text(count > 99 ? "99+" : "\(count)")
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(theme.badgeInk)
      .padding(.horizontal, count > 9 ? 4 : 3)
      .padding(.vertical, 1)
      .background(theme.badge, in: Capsule())
      .accessibilityHidden(true)
  }
}
