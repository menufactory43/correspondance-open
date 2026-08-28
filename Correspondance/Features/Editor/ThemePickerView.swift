import SwiftUI

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
      columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.sm)],
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
            swatch(WritingTheme.resolve(id))
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
        HStack {
          swatch(theme)
          Spacer()
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(theme.accent)
          }
        }
        Text(id.labelFR)
          .font(Typography.sidebarItem)
          .foregroundStyle(theme.ink)
        Text(id.subtitleFR)
          .font(Typography.meta)
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.paper)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? theme.accent : theme.edge, lineWidth: selected ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func swatch(_ theme: WritingTheme) -> some View {
    ZStack {
      Circle()
        .fill(theme.paper)
        .frame(width: 28, height: 28)
        .overlay(
          Circle()
            .strokeBorder(theme.edge, lineWidth: 1)
        )
      Circle()
        .fill(theme.ink)
        .frame(width: 12, height: 12)
        .offset(x: 6, y: 6)
    }
    .frame(width: 34, height: 34)
  }
}
