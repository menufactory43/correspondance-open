import AppKit
import SwiftUI

struct ComposerBar: View {
  @Binding var text: String
  @Binding var attachmentPaths: [String]
  var isSending: Bool
  var theme: WritingTheme
  var onAttach: () -> Void
  var onSend: () -> Void

  @Environment(ThemePreferences.self) private var themes

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !attachmentPaths.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(attachmentPaths.enumerated()), id: \.offset) { index, path in
              ZStack(alignment: .topTrailing) {
                if let img = NSImage(contentsOfFile: path) {
                  Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                  Image(systemName: "doc")
                    .frame(width: 64, height: 64)
                    .background(theme.paperSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Button {
                  attachmentPaths.remove(at: index)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
              }
            }
          }
          .padding(.horizontal, Spacing.md)
        }
      }

      HStack(alignment: .bottom, spacing: Spacing.sm) {
        SoftToolButton(systemImage: "photo", helpText: "Joindre une image") {
          onAttach()
        }

        TextField("Écrire une réponse…", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(Typography.composer(themes.typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1...6)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        SoftToolButton(
          systemImage: "arrow.up.circle.fill",
          helpText: "Envoyer",
          isEmphasized: true,
          isDisabled: !canSend || isSending
        ) {
          onSend()
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }
}
