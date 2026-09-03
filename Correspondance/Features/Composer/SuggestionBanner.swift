import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// La réponse que « cc » propose **sans qu'on demande** (`AgentProposal.Kind
/// .suggest`), en bandeau compact au-dessus de la saisie — pas en carte dans
/// le fil : une proposition qu'on n'a pas sollicitée ne doit pas prendre la
/// place d'un message.
///
/// Trois issues, toutes locales : « Envoyer » fait partir le texte comme mon
/// message ; un clic sur le texte le descend dans la saisie ; se mettre à
/// écrire, ou un message qui arrive, la fait disparaître.
struct SuggestionBanner: View {
  let proposal: AgentProposal
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var onSend: () -> Void
  var onOpen: () -> Void
  var onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.accent)
      Text(proposal.headerFR)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
        .fixedSize()

      Button(action: onOpen) {
        Text(proposal.text.replacingOccurrences(of: "\n", with: " "))
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Ouvrir dans la saisie")
      .accessibilityLabel("Ouvrir la proposition dans la saisie : \(proposal.text)")

      Button(action: onSend) {
        HStack(spacing: 4) {
          Image(systemName: "paperplane")
            .font(.system(size: 10, weight: .semibold))
          Text("Envoyer")
            .font(Typography.meta(typeface))
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.accent.opacity(0.14))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Envoyer tel quel")

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.inkTertiary)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Ignorer")
      .accessibilityLabel("Ignorer la proposition")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.paperSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    )
    .padding(.horizontal, Spacing.md)
    .padding(.top, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(proposal.headerFR) : \(proposal.text)")
  }
}
