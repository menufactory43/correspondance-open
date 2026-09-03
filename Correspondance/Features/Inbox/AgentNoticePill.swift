import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// L'avis de « cc » sur lui-même, au milieu du fil : une pastille centrée,
/// grise quand il passe la main, rouge quand quelque chose a cassé (moteur
/// absent, délai, erreur), avec le geste qu'il propose — « Relancer » sa
/// machine, ou « Réessayer » le dernier aparté.
struct AgentNoticePill: View {
  let notice: AgentNotice
  let theme: WritingTheme
  let typeface: WritingTypeface
  var onAction: (() -> Void)?

  private var tint: Color { notice.isFailure ? Color.red : theme.inkTertiary }

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(tint)
        .frame(width: 5, height: 5)
      Text(notice.body)
        .font(Typography.meta(typeface))
        .foregroundStyle(notice.isFailure ? theme.ink : theme.inkTertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let action = notice.action, let onAction {
        Button(action: onAction) {
          Text(action.labelFR)
            .font(Typography.meta(typeface))
            .foregroundStyle(notice.isFailure ? Color.red : theme.accent)
            .underline()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.labelFR) \(notice.agent)")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      Capsule(style: .continuous)
        .fill(notice.isFailure ? Color.red.opacity(0.08) : theme.paperSecondary)
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(notice.isFailure ? Color.red.opacity(0.35) : theme.edge, lineWidth: 0.8)
    )
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xxs)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(notice.agent) : \(notice.body)")
  }
}

/// « ● Envoyé par cc pour vous · 14:02 » — sous une bulle que l'agent a
/// envoyée en mon nom. Le point est rouge : c'est le mode qui engage.
struct PilotedFootnote: View {
  let agent: String
  let sentAt: Date
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(Color.red)
        .frame(width: 5, height: 5)
      Text("Envoyé par \(agent) pour vous · \(sentAt.formatted(date: .omitted, time: .shortened))")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 4)
    .accessibilityLabel("Envoyé par \(agent) pour vous")
  }
}
