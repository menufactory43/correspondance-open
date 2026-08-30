import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct ThemePickerView: View {
  @Binding var selection: WritingThemeID
  var compact: Bool = false

  var body: some View {
    if compact {
      compactList
    } else {
      grid
    }
  }

  private var grid: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 176), spacing: Spacing.sm)],
      spacing: Spacing.sm
    ) {
      ForEach(WritingThemeID.allCases) { id in
        themeCard(id)
      }
    }
  }

  private var compactList: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(WritingThemeID.allCases) { id in
        Button {
          selection = id
        } label: {
          HStack(spacing: Spacing.sm) {
            ThemePreview(theme: WritingTheme.resolve(id), width: 76, height: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(id.labelFR)
              Text(id.subtitleFR)
                .font(Typography.meta)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if selection == id {
              Image(systemName: "checkmark")
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? [.isSelected] : [])
      }
    }
  }

  private func themeCard(_ id: WritingThemeID) -> some View {
    let theme = WritingTheme.resolve(id)
    let selected = selection == id
    return Button {
      selection = id
    } label: {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ThemePreview(theme: theme, width: nil, height: 84)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(id.labelFR)
            .font(Typography.sidebarItem)
            .foregroundStyle(theme.ink)
          Spacer(minLength: 4)
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(theme.accent)
          }
        }
        Text(id.subtitleFR)
          .font(Typography.meta)
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(theme.paper)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(id.labelFR). \(id.subtitleFR)")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// L'APERÇU RÉEL d'un thème : son papier, sa sidebar, une bulle entrante et une
/// bulle sortante. On montre ce que le thème FAIT, pas deux pastilles de
/// couleur — c'est la seule façon de choisir sans essayer.
private struct ThemePreview: View {
  let theme: WritingTheme
  var width: CGFloat?
  var height: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      // La colonne : rail + liste, comme dans la fenêtre.
      HStack(spacing: 0) {
        theme.rail.frame(width: height * 0.12)
        theme.sidebar.frame(width: height * 0.26)
      }

      // Le fil : papier, une bulle reçue, une bulle envoyée.
      ZStack {
        theme.paper
        VStack(alignment: .leading, spacing: height * 0.11) {
          bubble(fill: theme.bubbleIn, ink: theme.bubbleInInk, width: 0.62)
            .frame(maxWidth: .infinity, alignment: .leading)
          bubble(fill: theme.bubbleOut, ink: theme.bubbleOutInk, width: 0.48)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, height * 0.12)
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.separator, lineWidth: 1)
    )
    .accessibilityHidden(true)
  }

  private func bubble(fill: Color, ink: Color, width factor: CGFloat) -> some View {
    GeometryReader { proxy in
      Capsule(style: .continuous)
        .fill(fill)
        .frame(width: proxy.size.width * factor, height: height * 0.2)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(ink)
            .frame(width: proxy.size.width * factor * 0.5, height: height * 0.055)
            .padding(.leading, height * 0.06)
        }
    }
    .frame(height: height * 0.2)
  }
}
